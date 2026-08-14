"""
Model Router — multi-model selection with fallback and task-based routing.
Phase 2: reads config from ~/.kamila_models.json, discovers Ollama models,
selects best model per task type, and wraps OllamaInterface with fallback logic.
"""

module ModelRouter

using JSON
using HTTP
using ..OllamaInterface
using ..Errors

export ModelConfig,
    get_router_config,
    save_router_config,
    discover_models,
    select_model,
    query_with_router,
    query_router_stream,
    query_router_chat_stream,
    get_active_model,
    set_active_model,
    validate_model,
    modelconfig_to_dict,
    MODEL_TYPES,
    DEFAULT_MODELS

# ─── Task Types ──────────────────────────────────────────

const MODEL_TYPES = [:chat, :code, :quick, :vision, :default]

# ─── Config Struct ───────────────────────────────────────

struct ModelConfig
    name::String
    label::String
    task_type::Symbol
    priority::Int
    max_tokens::Int
    temperature::Float64
    enabled::Bool
    endpoint::String  # custom endpoint, empty = default OLLAMA_HOST
end

function ModelConfig(;
    name,
    label = "",
    task_type = :default,
    priority = 1,
    max_tokens = 2000,
    temperature = 0.7,
    enabled = true,
    endpoint = "",
)
    label = isempty(label) ? name : label
    ModelConfig(
        name,
        label,
        task_type,
        priority,
        max_tokens,
        temperature,
        enabled,
        endpoint,
    )
end

function modelconfig_from_dict(d::Dict)
    ModelConfig(
        name = get(d, "name", ""),
        label = get(d, "label", get(d, "name", "")),
        task_type = Symbol(get(d, "task_type", "default")),
        priority = get(d, "priority", 1),
        max_tokens = get(d, "max_tokens", 2000),
        temperature = get(d, "temperature", 0.7),
        enabled = get(d, "enabled", true),
        endpoint = get(d, "endpoint", ""),
    )
end

function modelconfig_to_dict(c::ModelConfig)
    Dict(
        "name" => c.name,
        "label" => c.label,
        "task_type" => string(c.task_type),
        "priority" => c.priority,
        "max_tokens" => c.max_tokens,
        "temperature" => c.temperature,
        "enabled" => c.enabled,
        "endpoint" => c.endpoint,
    )
end

# ─── Config File ─────────────────────────────────────────

const CONFIG_PATH =
    get(ENV, "KAMILA_MODELS_CONFIG", joinpath(homedir(), ".kamila_models.json"))

const DEFAULT_MODELS = [
    ModelConfig(
        name = "kamila1",
        label = "Kamila1 (Online)",
        task_type = :chat,
        priority = 1,
        max_tokens = 4000,
        temperature = 0.7,
    ),
    ModelConfig(
        name = "kamila1",
        label = "Kamila1 (Code)",
        task_type = :code,
        priority = 1,
        max_tokens = 8000,
        temperature = 0.3,
    ),
    ModelConfig(
        name = "kamila2",
        label = "Kamila2 (Offline)",
        task_type = :chat,
        priority = 2,
        max_tokens = 4000,
        temperature = 0.7,
    ),
    ModelConfig(
        name = "kamila2",
        label = "Kamila2 (Code)",
        task_type = :code,
        priority = 2,
        max_tokens = 8000,
        temperature = 0.3,
    ),
    ModelConfig(
        name = "qwen2.5-coder:0.5b",
        label = "Quick Reply",
        task_type = :quick,
        priority = 1,
        max_tokens = 100,
        temperature = 0.5,
    ),
]

function get_router_config()
    if !isfile(CONFIG_PATH)
        return deepcopy(DEFAULT_MODELS)
    end
    try
        data = JSON.parse(read(CONFIG_PATH, String))
        models_data = get(data, "models", [])
        if isempty(models_data)
            return deepcopy(DEFAULT_MODELS)
        end
        return [modelconfig_from_dict(m) for m in models_data]
    catch
        return deepcopy(DEFAULT_MODELS)
    end
end

function save_router_config(models::Vector{ModelConfig})
    data = Dict("models" => [modelconfig_to_dict(m) for m in models])
    write(CONFIG_PATH, JSON.json(data, 2))
    return true
end

# ─── Model Discovery ─────────────────────────────────────

function discover_models()
    try
        r = HTTP.request(
            "GET",
            "$OLLAMA_HOST/api/tags",
            [],
            "";
            retry = false,
            reuse_limit = 0,
            require_ssl_verification = false,
        )
        data = JSON.parse(String(r.body))
        models = get(data, "models", [])
        return [
            Dict(
                "name" => m["name"],
                "size" => m["size"],
                "parameter_size" => get(get(m, "details", Dict()), "parameter_size", ""),
                "quantization" => get(get(m, "details", Dict()), "quantization_level", ""),
                "family" => get(get(m, "details", Dict()), "family", ""),
                "capabilities" => get(m, "capabilities", []),
            ) for m in models
        ]
    catch
        return []
    end
end

# ─── Model Selection ─────────────────────────────────────

function select_model(
    task_type::Symbol = :chat,
    models::Vector{ModelConfig} = get_router_config(),
)
    # Filter enabled models matching task type (or :default as fallback)
    candidates = filter(
        m -> m.enabled && (m.task_type == task_type || m.task_type == :default),
        models,
    )
    if isempty(candidates)
        candidates = filter(m -> m.enabled, models)
    end
    # Pick lowest priority number (1 = highest)
    sort!(candidates, by = m -> m.priority)
    return isempty(candidates) ? ModelConfig(name = "kamila:latest") : candidates[1]
end

function select_model_fallback(
    task_type::Symbol = :chat,
    models::Vector{ModelConfig} = get_router_config(),
)
    enabled = filter(m -> m.enabled, models)
    # Return all matching models sorted by priority, for fallback chaining
    matches = filter(m -> m.task_type == task_type || m.task_type == :default, enabled)
    sort!(matches, by = m -> m.priority)
    return matches
end

# ─── Active Model Override ───────────────────────────────

const ACTIVE_MODEL = Ref{String}("")

function get_active_model()
    if isempty(ACTIVE_MODEL[])
        cfg = get_router_config()
        m = select_model(:chat, cfg)
        return m.name
    end
    return ACTIVE_MODEL[]
end

function set_active_model(name::String)
    ACTIVE_MODEL[] = name
    return name
end

# ─── Error Detection ─────────────────────────────────────

const ERROR_PREFIXES = ["❌", "error:", "timeout", "connection refused", "could not connect"]

# A structured Kamila error string looks like "Error [category] message".
const ERROR_CATEGORY_RE = r"^Error\s+\[(\w+)\]"i

"""
Extract the error category from a structured error string ("Error [timeout] ...")
or a plain prefix match. Returns a Symbol (one of the taxonomy categories) or
`:internal` for an unrecognized error, `nothing` when the string is not an error.
"""
function error_category_of(s::String)
    isempty(s) && return :internal
    lower = lowercase(s)

    m = match(ERROR_CATEGORY_RE, lower)
    if m !== nothing
        cat = Symbol(m.captures[1])
        cat in Errors.CATEGORIES && return cat
        return :internal
    end

    for prefix in ERROR_PREFIXES
        if startswith(lower, prefix)
            return prefix == "error:" ? :internal : :network
        end
    end
    return nothing
end

function is_error_response(s::String)
    return error_category_of(s) !== nothing
end

# ─── Model Validation ────────────────────────────────────

function validate_model(name::String)
    if name in ("kamila:latest", "kamila1", "kamila2")
        return true  # always valid — built-in Kamila models
    end
    discovered = discover_models()
    for m in discovered
        if m["name"] == name
            return true
        end
    end
    return false
end

# ─── Auto Config ─────────────────────────────────────────

function auto_config_model(name::String, task_type::Symbol)
    discovered = discover_models()
    for d in discovered
        if d["name"] == name
            param = d["parameter_size"]
            caps = d["capabilities"]
            auto_tokens = 2000
            if !isempty(param)
                numeric = replace(param, r"[A-Za-z]" => "")
                unit = replace(param, r"[0-9.]" => "")
                size_val = tryparse(Float64, numeric)
                if size_val !== nothing
                    # Convert to billions of parameters
                    if unit == "M" || unit == "MB"
                        size_val /= 1000
                    end
                    auto_tokens = size_val >= 1 ? 8000 : 2000
                end
            end
            auto_temp = "thinking" in caps ? 0.6 : 0.7
            return ModelConfig(
                name = name,
                task_type = task_type,
                max_tokens = auto_tokens,
                temperature = auto_temp,
            )
        end
    end
    return ModelConfig(name = name, task_type = task_type)
end

# ─── Router-Aware Query ──────────────────────────────────

const OLLAMA_HOST = get(ENV, "OLLAMA_HOST", "http://localhost:11434")

function query_with_router(
    prompt::String;
    system_prompt::String = "",
    temperature::Float64 = -1,
    max_tokens::Int = -1,
    task_type::Symbol = :chat,
    prefer_model::String = "",
)
    models = get_router_config()
    errors = String[]

    # Use active model override if set
    if !isempty(ACTIVE_MODEL[])
        active = ACTIVE_MODEL[]
        configs = filter(m -> m.name == active && m.enabled, models)
        cfg = if isempty(configs)
            auto_config_model(active, task_type)
        else
            first(configs)
        end
        temp = temperature >= 0 ? temperature : cfg.temperature
        tokens = max_tokens > 0 ? max_tokens : cfg.max_tokens
        result = query_model(cfg, prompt, system_prompt, temp, tokens)
        if !is_error_response(result)
            return result
        end
        push!(errors, "active($(cfg.name)): $result")
        # Fall through to chained fallback below
    end

    # Use prefer_model if specified
    if !isempty(prefer_model)
        cfg = auto_config_model(prefer_model, task_type)
        temp = temperature >= 0 ? temperature : cfg.temperature
        tokens = max_tokens > 0 ? max_tokens : cfg.max_tokens
        result = query_model(cfg, prompt, system_prompt, temp, tokens)
        if !is_error_response(result)
            return result
        end
        push!(errors, "preferred($(cfg.name)): $result")
        # Fall through to chained fallback below
    end

    # Normal: try fallback chain
    chain = select_model_fallback(task_type, models)
    for cfg in chain
        temp = temperature >= 0 ? temperature : cfg.temperature
        tokens = max_tokens > 0 ? max_tokens : cfg.max_tokens
        result = query_model(cfg, prompt, system_prompt, temp, tokens)
        if !is_error_response(result)
            return result
        end
        push!(errors, "$(cfg.name): $result")
    end

    return "❌ All models failed:\n" * join(errors, "\n")
end

function query_model(
    cfg::ModelConfig,
    prompt::String,
    system_prompt::String,
    temperature::Float64,
    max_tokens::Int,
)
    host = isempty(cfg.endpoint) ? OLLAMA_HOST : cfg.endpoint
    try
        payload = Dict(
            "model" => cfg.name,
            "prompt" => prompt,
            "system" => system_prompt,
            "stream" => false,
            "options" =>
                Dict("temperature" => temperature, "num_predict" => max_tokens),
        )
        headers = ["Content-Type" => "application/json"]
        response = HTTP.request(
            "POST",
            "$host/api/generate",
            headers,
            JSON.json(payload);
            readtimeout = 60,
            retry = false,
            reuse_limit = 0,
            require_ssl_verification = false,
        )

        if response.status == 200
            result = JSON.parse(String(response.body))
            return get(result, "response", "")
        else
            return "❌ Model '$(cfg.name)' returned status $(response.status)"
        end
    catch e
        return "❌ Model '$(cfg.name)' error: $e"
    end
end

function query_router_stream(
    prompt::String;
    system_prompt::String = "",
    temperature::Float64 = -1,
    max_tokens::Int = -1,
    task_type::Symbol = :chat,
    prefer_model::String = "",
)
    channel = Channel{String}(1)
    @async try
        result = query_with_router(
            prompt,
            system_prompt = system_prompt,
            temperature = temperature,
            max_tokens = max_tokens,
            task_type = task_type,
            prefer_model = prefer_model,
        )
        if !isempty(result)
            put!(channel, result)
        end
    catch e
        put!(channel, "❌ Error: $e")
    finally
        close(channel)
    end
    return channel
end

"""
True token-by-token streaming with fallback chain.
Streams tokens from the first model that succeeds; if it fails, falls through to next model.
"""
function query_router_stream_raw(
    prompt::String;
    system_prompt::String = "",
    temperature::Float64 = -1,
    max_tokens::Int = -1,
    task_type::Symbol = :chat,
    prefer_model::String = "",
)
    channel = Channel{String}(32)
    @async try
        models = get_router_config()
        errors = String[]

        # Active model override
        if !isempty(ACTIVE_MODEL[])
            active = ACTIVE_MODEL[]
            configs = filter(m -> m.name == active && m.enabled, models)
            cfg = if isempty(configs)
                auto_config_model(active, task_type)
            else
                first(configs)
            end
            temp = temperature >= 0 ? temperature : cfg.temperature
            tokens = max_tokens > 0 ? max_tokens : cfg.max_tokens

            for chunk in OllamaInterface.query_ollama_stream_raw(
                prompt;
                model = cfg.name,
                system_prompt,
                temperature = temp,
                max_tokens = tokens,
            )
                if is_error_response(chunk)
                    push!(errors, "active($(cfg.name)): $chunk")
                    break  # break out to fallback
                end
                put!(channel, chunk)
            end
            if isempty(errors) || errors[end] != "active($(cfg.name)): $(chunk)"
                close(channel)
                return
            end
        end

        # Prefer model
        if !isempty(prefer_model)
            cfg = auto_config_model(prefer_model, task_type)
            temp = temperature >= 0 ? temperature : cfg.temperature
            tokens = max_tokens > 0 ? max_tokens : cfg.max_tokens

            for chunk in OllamaInterface.query_ollama_stream_raw(
                prompt;
                model = cfg.name,
                system_prompt,
                temperature = temp,
                max_tokens = tokens,
            )
                if is_error_response(chunk)
                    push!(errors, "preferred($(cfg.name)): $chunk")
                    break
                end
                put!(channel, chunk)
            end
            if isempty(errors) || errors[end] != "preferred($(cfg.name)): $(chunk)"
                close(channel)
                return
            end
        end

        # Fallback chain
        chain = select_model_fallback(task_type, models)
        for cfg in chain
            temp = temperature >= 0 ? temperature : cfg.temperature
            tokens = max_tokens > 0 ? max_tokens : cfg.max_tokens

            success = false
            for chunk in OllamaInterface.query_ollama_stream_raw(
                prompt;
                model = cfg.name,
                system_prompt,
                temperature = temp,
                max_tokens = tokens,
            )
                if is_error_response(chunk)
                    push!(errors, "$(cfg.name): $chunk")
                    break
                end
                put!(channel, chunk)
                success = true
            end
            if success
                close(channel)
                return
            end
        end

        put!(channel, "❌ All models failed:\n" * join(errors, "\n"))
    catch e
        put!(channel, "❌ Error: $e")
    finally
        close(channel)
    end
    return channel
end

function query_router_chat_stream(
    messages::Vector;
    temperature::Float64 = -1.0,
    max_tokens::Int = -1,
    task_type::Symbol = :chat,
    prefer_model::String = "",
    model_ref::Union{Nothing,Base.RefValue{String}} = nothing,
)
    channel = Channel{OllamaInterface.StreamItem}(32)
    @async try
        models = get_router_config()
        errors = String[]

        if !isempty(ACTIVE_MODEL[])
            active = ACTIVE_MODEL[]
            configs = filter(m -> m.name == active && m.enabled, models)
            cfg = if isempty(configs)
                auto_config_model(active, task_type)
            else
                first(configs)
            end
            temp = temperature >= 0 ? temperature : cfg.temperature
            tokens = max_tokens > 0 ? max_tokens : cfg.max_tokens

            ok = true
            for item in OllamaInterface.query_ollama_chat_stream(
                messages;
                model = cfg.name,
                temperature = temp,
                max_tokens = tokens,
            )
                if is_error_response(item.text)
                    push!(errors, "active($(cfg.name)): $(item.text)")
                    ok = false
                    break
                end
                put!(channel, item)
            end
            if ok
                model_ref !== nothing && (model_ref[] = cfg.name)
                close(channel)
                return
            end
        end

        if !isempty(prefer_model)
            cfg = auto_config_model(prefer_model, task_type)
            temp = temperature >= 0 ? temperature : cfg.temperature
            tokens = max_tokens > 0 ? max_tokens : cfg.max_tokens

            ok = true
            for item in OllamaInterface.query_ollama_chat_stream(
                messages;
                model = cfg.name,
                temperature = temp,
                max_tokens = tokens,
            )
                if is_error_response(item.text)
                    push!(errors, "preferred($(cfg.name)): $(item.text)")
                    ok = false
                    break
                end
                put!(channel, item)
            end
            if ok
                model_ref !== nothing && (model_ref[] = cfg.name)
                close(channel)
                return
            end
        end

        chain = select_model_fallback(task_type, models)
        for cfg in chain
            temp = temperature >= 0 ? temperature : cfg.temperature
            tokens = max_tokens > 0 ? max_tokens : cfg.max_tokens

            success = false
            for item in OllamaInterface.query_ollama_chat_stream(
                messages;
                model = cfg.name,
                temperature = temp,
                max_tokens = tokens,
            )
                if is_error_response(item.text)
                    push!(errors, "$(cfg.name): $(item.text)")
                    break
                end
                put!(channel, item)
                success = true
            end
            if success
                model_ref !== nothing && (model_ref[] = cfg.name)
                close(channel)
                return
            end
        end

        put!(
            channel,
            OllamaInterface.StreamItem(
                "❌ All models failed:\n" * join(errors, "\n"),
                false,
            ),
        )
    catch e
        put!(channel, OllamaInterface.StreamItem("❌ Error: $e", false))
    finally
        close(channel)
    end
    return channel
end

end # module
