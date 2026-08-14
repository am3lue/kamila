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

export AgentEvent, run_agent_stream, run_agent_sync

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

# ─── Synchronous version (for non-streaming use) ───────────

function run_agent_sync(
    prompt::String;
    system_prompt::String = "",
    task_type::Symbol = :chat,
    model::String = "",
    max_iterations::Int = 10,
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
                AgentTools.execute_tool_structured(tool_name, tool_args)
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

end # module
