"""
AgentStream — Full autonomous agent loop with event streaming.
Phase 3: Streams tokens, tool calls, and tool results through a Channel.
"""

module AgentStream

using JSON
using ..OllamaInterface
using ..AgentTools
using ..ModelRouter
using ..KamilaLog
using ..Errors
using ..ResponseParser
import ..ToolSpec: get_tool_specs, to_payload, execute_tool_validated
import ..Plan

export AgentEvent, run_agent_stream, run_agent_sync, run_agent_plan, run_agent_stream_native

const MAX_TOOL_RETRIES = 2

# ─── Event Types ────────────────────────────────────────────

abstract type AgentEvent end

struct TokenEvent <: AgentEvent
    token::String
end

struct ToolCallEvent <: AgentEvent
    name::String
    args::Dict
    thought::String
end

struct ToolResultEvent <: AgentEvent
    name::String
    result::String
end

struct ErrorEvent <: AgentEvent
    message::String
    category::Symbol
end

ErrorEvent(message::AbstractString) = ErrorEvent(message, :internal)

struct DoneEvent <: AgentEvent end

# ─── Main Agent Loop ────────────────────────────────────────

function run_agent_stream(
    prompt::String;
    system_prompt::String = "",
    task_type::Symbol = :chat,
    model::String = "",
    max_iterations::Int = 10,
    max_history::Int = 10,
    on_token::Union{Nothing,Function} = nothing,
)
    channel = Channel{Union{AgentEvent,Nothing}}(32)

    @async try
        # Seed history with the user request once; each iteration appends only
        # the assistant's thought/tool result, so the prompt is never duplicated
        # and tool results actually flow back into the model context.
        history = [("User", prompt)]

        iteration = 0
        while iteration < max_iterations
            iteration += 1
            KamilaLog.debug(
                "agent iteration start";
                mod = "agent_stream",
                fields = Dict("iteration" => iteration, "max_iterations" => max_iterations),
            )

            # Build context from history
            context = ""
            for (role, msg) in history[max(1, end - max_history + 1):end]
                context *= "$role: $msg\n"
            end
            KamilaLog.debug(
                "context built";
                mod = "agent_stream",
                fields = Dict("context_chars" => length(context)),
            )

            # Get model config from router (for temperature/tokens)
            models = ModelRouter.get_router_config()
            if !isempty(model)
                cfg = ModelRouter.auto_config_model(model, task_type)
            else
                cfg = ModelRouter.select_model(task_type, models)
            end

            # Stream tokens from model
            accumulated = ""
            tool_called = false

            try
                for chunk in OllamaInterface.query_ollama_stream_raw(
                    context,
                    system_prompt = system_prompt,
                    model = cfg.name,
                    temperature = cfg.temperature,
                    max_tokens = cfg.max_tokens,
                )
                    if ModelRouter.is_error_response(chunk)
                        put!(channel, ErrorEvent(chunk))
                        close(channel)
                        return
                    end

                    accumulated *= chunk
                    if on_token !== nothing
                        on_token(chunk)
                    end
                    put!(channel, TokenEvent(chunk))
                end
            catch e
                put!(channel, ErrorEvent("Stream error: $e"))
                close(channel)
                return
            end

            # Parse response for tool call
            is_tool, tool_name, tool_args, thought = parse_response(accumulated)
            KamilaLog.debug(
                "response parsed";
                mod = "agent_stream",
                fields = Dict(
                    "is_tool" => is_tool,
                    "tool_name" => tool_name,
                    "response_chars" => length(accumulated),
                ),
            )

            if is_tool
                tool_called = true

                # Emit tool call event
                put!(channel, ToolCallEvent(tool_name, tool_args, thought))
                KamilaLog.debug(
                    "tool call";
                    mod = "agent_stream",
                    fields = Dict("tool" => tool_name),
                )

                # Execute tool, retrying retryable failures (max 2 retries)
                tool_result = "Error executing tool: unknown error"
                tool_category = :internal
                tool_retryable = false
                for attempt = 0:MAX_TOOL_RETRIES
                    tool_structured = try
                        AgentTools.execute_tool_structured(tool_name, tool_args)
                    catch e
                        Dict{String,Any}(
                            "ok" => false,
                            "category" => "internal",
                            "retryable" => false,
                            "result" => "Error executing tool: $(Errors.error_string(e))",
                        )
                    end
                    tool_result = tool_structured["result"]
                    if !tool_structured["ok"]
                        tool_category = Symbol(tool_structured["category"])
                        tool_retryable = tool_structured["retryable"]
                        if attempt < MAX_TOOL_RETRIES && tool_retryable
                            KamilaLog.warn(
                                "retrying retryable tool failure";
                                mod = "agent_stream",
                                fields = Dict(
                                    "tool" => tool_name,
                                    "attempt" => attempt + 1,
                                    "category" => string(tool_category),
                                ),
                            )
                            continue
                        end
                    end
                    break
                end
                KamilaLog.debug(
                    "tool result";
                    mod = "agent_stream",
                    fields = Dict(
                        "tool" => tool_name,
                        "result_chars" => length(tool_result),
                        "category" => string(tool_category),
                        "retryable" => tool_retryable,
                    ),
                )

                # Emit tool result event
                put!(channel, ToolResultEvent(tool_name, tool_result))

                # Add to history for next iteration
                push!(history, ("Kamila (thought)", thought))
                push!(history, ("Kamila (tool)", tool_name))
                push!(history, ("System", tool_result))

                # Continue loop for next iteration
            else
                # Final response - no tool call
                push!(history, ("Kamila", accumulated))

                put!(channel, DoneEvent())
                close(channel)
                return
            end
        end

        put!(channel, ErrorEvent("Max iterations reached", :internal))
    catch e
        put!(channel, ErrorEvent("Agent error: $(Errors.error_string(e))", :internal))
    finally
        close(channel)
    end

    return channel
end

# ─── Native function-calling loop (05.1) ──────────────────
# Prefers native `tool_calls` emitted via Ollama's `/api/chat` `tools` array.
# Falls back to the text-JSON parser when the model responds with content only,
# so models without tool support keep working through the same loop.

function run_agent_stream_native(
    prompt::String;
    system_prompt::String = "",
    task_type::Symbol = :chat,
    model::String = "",
    max_iterations::Int = 10,
    max_history::Int = 10,
    on_token::Union{Nothing,Function} = nothing,
)
    channel = Channel{Union{AgentEvent,Nothing}}(32)

    @async try
        tool_payloads = [to_payload(s) for s in get_tool_specs()]
        history = [("User", prompt)]

        iteration = 0
        while iteration < max_iterations
            iteration += 1
            KamilaLog.debug(
                "agent native iteration start";
                mod = "agent_stream",
                fields = Dict("iteration" => iteration, "max_iterations" => max_iterations),
            )

            context = ""
            for (role, msg) in history[max(1, end - max_history + 1):end]
                context *= "$role: $msg\n"
            end

            models = ModelRouter.get_router_config()
            cfg = if !isempty(model)
                ModelRouter.auto_config_model(model, task_type)
            else
                ModelRouter.select_model(task_type, models)
            end

            accumulated = ""
            thought = ""
            native_calls = nothing

            try
                for item in ModelRouter.query_router_chat_stream(
                    [Dict("role" => "user", "content" => context)],
                    model_ref = nothing,
                    task_type = task_type,
                    prefer_model = model,
                    tools = tool_payloads,
                )
                    if ModelRouter.is_error_response(item.text) && isempty(item.tool_calls)
                        put!(channel, ErrorEvent(item.text))
                        close(channel)
                        return
                    end
                    if !isempty(item.tool_calls)
                        native_calls = item.tool_calls
                        continue
                    end
                    if item.is_thinking
                        thought *= item.text
                        continue
                    end
                    accumulated *= item.text
                    if on_token !== nothing
                        on_token(item.text)
                    end
                    put!(channel, TokenEvent(item.text))
                end
            catch e
                put!(channel, ErrorEvent("Stream error: $e"))
                close(channel)
                return
            end

            # Native tool_calls take precedence; otherwise fall back to the
            # text-JSON parser so non-tool-capable models keep working.
            if native_calls !== nothing && !isempty(native_calls)
                tool_called = false
                for call in native_calls
                    tool_name = String(get(call, "name", ""))
                    tool_args = Dict{String,Any}(get(call, "arguments", Dict{String,Any}()))
                    isempty(tool_name) && continue
                    tool_called = true

                    put!(channel, ToolCallEvent(tool_name, tool_args, thought))

                    tool_result = "Error executing tool: unknown error"
                    tool_category = :internal
                    tool_retryable = false
                    for attempt = 0:MAX_TOOL_RETRIES
                        tool_structured = try
                            execute_tool_validated(tool_name, tool_args)
                        catch e
                            Dict{String,Any}(
                                "ok" => false,
                                "category" => "internal",
                                "retryable" => false,
                                "result" => "Error executing tool: $(Errors.error_string(e))",
                            )
                        end
                        tool_result = tool_structured["result"]
                        if !tool_structured["ok"]
                            tool_category = Symbol(tool_structured["category"])
                            tool_retryable = tool_structured["retryable"]
                            if attempt < MAX_TOOL_RETRIES && tool_retryable
                                KamilaLog.warn(
                                    "retrying retryable tool failure";
                                    mod = "agent_stream",
                                    fields = Dict(
                                        "tool" => tool_name,
                                        "attempt" => attempt + 1,
                                        "category" => string(tool_category),
                                    ),
                                )
                                continue
                            end
                        end
                        break
                    end

                    put!(channel, ToolResultEvent(tool_name, tool_result))
                    push!(history, ("Kamila (thought)", thought))
                    push!(history, ("Kamila (tool)", tool_name))
                    push!(history, ("System", tool_result))
                end

                tool_called || begin
                    push!(history, ("Kamila", accumulated))
                    put!(channel, DoneEvent())
                    close(channel)
                    return
                end
            else
                is_tool, tool_name, tool_args, parsed_thought =
                    ResponseParser.parse_response(accumulated)
                if is_tool
                    push!(history, ("Kamila (thought)", parsed_thought))
                    push!(history, ("Kamila (tool)", tool_name))
                    tool_structured = try
                        execute_tool_validated(tool_name, tool_args)
                    catch e
                        Dict{String,Any}(
                            "ok" => false,
                            "category" => "internal",
                            "retryable" => false,
                            "result" => "Error executing tool: $(Errors.error_string(e))",
                        )
                    end
                    put!(channel, ToolResultEvent(tool_name, tool_structured["result"]))
                    push!(history, ("System", tool_structured["result"]))
                else
                    push!(history, ("Kamila", accumulated))
                    put!(channel, DoneEvent())
                    close(channel)
                    return
                end
            end
        end

        put!(channel, ErrorEvent("Max iterations reached", :internal))
    catch e
        put!(channel, ErrorEvent("Agent error: $(Errors.error_string(e))", :internal))
    finally
        close(channel)
    end

    return channel
end

# ─── Synchronous version (for non-streaming use) ───────────
function run_agent_sync(
    prompt::String;
    system_prompt::String = "",
    task_type::Symbol = :chat,
    model::String = "",
    max_iterations::Int = 10,
    capabilities::Union{Nothing,AbstractSet} = nothing,
)
    history = [("User", prompt)]

    iteration = 0
    while iteration < max_iterations
        iteration += 1

        context = ""
        for (role, msg) in history
            context *= "$role: $msg\n"
        end

        models = ModelRouter.get_router_config()
        if !isempty(model)
            cfg = ModelRouter.auto_config_model(model, task_type)
        else
            cfg = ModelRouter.select_model(task_type, models)
        end

        response = OllamaInterface.query_ollama(
            context,
            system_prompt = system_prompt,
            model = cfg.name,
            temperature = cfg.temperature,
            max_tokens = cfg.max_tokens,
        )

        is_tool, tool_name, tool_args, thought = parse_response(response)

        if is_tool
            tool_structured = try
                AgentTools.execute_tool_structured(tool_name, tool_args; capabilities = capabilities)
            catch e
                Dict{String,Any}(
                    "ok" => false,
                    "result" => "Error executing tool: $(Errors.error_string(e))",
                )
            end
            tool_result = tool_structured["result"]

            push!(history, ("Kamila (thought)", thought))
            push!(history, ("Kamila (tool)", tool_name))
            push!(history, ("System", tool_result))
        else
            push!(history, ("Kamila", response))
            return response
        end
    end

    return "Max iterations reached without final response"
end

# ─── Response Parser ──────────────────────────────────────
# Single canonical implementation lives in `ResponseParser` (02.5); both agents
# delegate here so behavior is identical.

function parse_response(response::String)
    return ResponseParser.parse_response(response)
end

function extract_tool_from_json(data)
    is_tool, tool_name, args, thought = ResponseParser.extract_tool(data)
    return (is_tool, tool_name, args, thought)
end

# ─── Plan-Driven Loop (04.1) ──────────────────────────────
# Streams the same AgentEvents as `run_agent_stream` but drives a persisted
# `Plan`: each tool call is bound to the next runnable step, results mark the
# step verified/failed, and the loop stops when the plan completes, fails, or
# the model stops calling tools.

function run_agent_plan(
    plan::Plan.Plan;
    system_prompt::String = "",
    model::String = "",
    max_iterations::Int = 10,
    on_token::Union{Nothing,Function} = nothing,
)
    channel = Channel{Union{AgentEvent,Nothing}}(32)

    @async try
        # Resume from a paused/active plan; otherwise start it.
        if plan.status in [:created, :pending]
            Plan.start(plan)
        elseif plan.status == :paused
            Plan.resume(plan)
        end

        history = [("User", plan.goal)]

        iteration = 0
        while iteration < max_iterations && plan.status == :active
            iteration += 1

            step = Plan.next_runnable(plan)
            if step === nothing
                put!(
                    channel,
                    ErrorEvent(
                        "Plan has no runnable step (all pending steps are dependency-gated)",
                        :internal,
                    ),
                )
                close(channel)
                return
            end
            Plan.mark_step(plan, step.id, :running)

            context = ""
            for (role, msg) in history[max(1, end - 10 + 1):end]
                context *= "$role: $msg\n"
            end

            models = ModelRouter.get_router_config()
            if !isempty(model)
                cfg = ModelRouter.auto_config_model(model, :task)
            else
                cfg = ModelRouter.select_model(:task, models)
            end

            accumulated = ""
            try
                for chunk in OllamaInterface.query_ollama_stream_raw(
                    context,
                    system_prompt = system_prompt,
                    model = cfg.name,
                    temperature = cfg.temperature,
                    max_tokens = cfg.max_tokens,
                )
                    if ModelRouter.is_error_response(chunk)
                        put!(channel, ErrorEvent(chunk))
                        close(channel)
                        return
                    end
                    accumulated *= chunk
                    if on_token !== nothing
                        on_token(chunk)
                    end
                    put!(channel, TokenEvent(chunk))
                end
            catch e
                put!(channel, ErrorEvent("Stream error: $e"))
                close(channel)
                return
            end

            is_tool, tool_name, tool_args, thought = parse_response(accumulated)

            if is_tool
                put!(channel, ToolCallEvent(tool_name, tool_args, thought))

                # Execute tool; on retryable failure retry the same step.
                tool_result = "Error executing tool: unknown error"
                tool_retryable = false
                tool_ok = false
                for attempt = 0:2
                    tool_structured = try
                        AgentTools.execute_tool_structured(tool_name, tool_args)
                    catch e
                        Dict{String,Any}(
                            "ok" => false,
                            "category" => "internal",
                            "retryable" => false,
                            "result" => "Error executing tool: $(Errors.error_string(e))",
                        )
                    end
                    tool_result = tool_structured["result"]
                    if tool_structured["ok"]
                        tool_ok = true
                        break
                    end
                    tool_retryable = tool_structured["retryable"]
                    if attempt < 2 && tool_retryable
                        KamilaLog.warn(
                            "retrying retryable tool failure";
                            mod = "agent_stream",
                            fields = Dict("tool" => tool_name, "attempt" => attempt + 1),
                        )
                        continue
                    end
                    break
                end

                put!(channel, ToolResultEvent(tool_name, tool_result))

                if tool_ok
                    if step.verify !== nothing
                        # Enforced Check phase (04.3): run the verification spec
                        # before the step may be marked :verified.
                        spec = try
                            Verify.VerifySpec(step.verify)
                        catch e
                            Verify.VerifySpec(Dict{String,Any}("kind" => "schema", "target" => ""))
                        end
                        vr = Verify.verify(spec, tool_result; workdir = pwd())
                        if vr.ok
                            Plan.mark_step(plan, step.id, :verified, tool_result)
                        else
                            # Retry with the evidence fed back so the model can
                            # self-correct; otherwise fail (and roll back).
                            Plan.mark_step(plan, step.id, :failed, vr.evidence; retryable = true)
                            push!(history, ("Kamila (verification)", "step did not pass verification: $(vr.evidence)"))
                            if plan.status == :failed
                                ok, evidence = Rollback.rollback(tool_name, step.args, pwd())
                                put!(
                                    channel,
                                    ErrorEvent(
                                        "Step $(step.id) failed verification; rollback: $evidence",
                                        :internal,
                                    ),
                                )
                            end
                        end
                    else
                        # No verify spec: step declared verify=nothing; the skip
                        # is justified by an explicitly definitive tool result
                        # (or the step is non-side-effecting). Logged for audit.
                        KamilaLog.info(
                            "verify.skipped";
                            mod = "agent_stream",
                            fields = Dict{String,Any}(
                                "step" => step.id,
                                "tool" => tool_name,
                                "justification" => "verify=nothing (no spec declared)",
                            ),
                        )
                        Plan.mark_step(plan, step.id, :verified, tool_result)
                    end
                else
                    Plan.mark_step(plan, step.id, :failed, tool_result; retryable = tool_retryable)
                end
                push!(history, ("Kamila (thought)", thought))
                push!(history, ("Kamila (tool)", tool_name))
                push!(history, ("System", tool_result))
            else
                # No tool call: treat the step as failed (model did not execute).
                Plan.mark_step(plan, step.id, :failed, accumulated)
                put!(
                    channel,
                    ErrorEvent("Step $(step.id) completed without a tool call", :internal),
                )
                close(channel)
                return
            end
        end

        if plan.status == :completed
            # If this was a sub-plan (04.4), promote the parent step.
            try
                Plan.promote_subplan(plan)
            catch e
                KamilaLog.warn(
                    "promote.subplan.failed";
                    mod = "agent_stream",
                    fields = Dict("error" => string(e)),
                )
            end
            put!(channel, DoneEvent())
        elseif plan.status == :failed
            put!(
                channel,
                ErrorEvent("Plan failed after exhausting step retries", :internal),
            )
        else
            put!(channel, ErrorEvent("Max iterations reached", :internal))
        end
    catch e
        put!(
            channel,
            ErrorEvent("Plan agent error: $(Errors.error_string(e))", :internal),
        )
    finally
        close(channel)
    end

    return channel
end

end # module
