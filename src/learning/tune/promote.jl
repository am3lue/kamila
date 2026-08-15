"""
TunePromote — merge a fine-tuned adapter into the ModelRouter config (07.2).

After the eval gate passes, add the adapter as a `task_type=:default`
low-priority (high number) model config entry. It is added `enabled=false`
so it is never auto-selected: the user reviews and opts in.
"""

module TunePromote

using JSON
using ..ModelRouter
using ..KamilaLog

export promote_adapter, adapter_registered

"""
    promote_adapter(; model_name, label="Fine-tuned adapter", task_type=:default,
                    priority=100, enabled=false, gate=nothing,
                    config_path=ModelRouter.CONFIG_PATH)

Register a fine-tuned adapter in the ModelRouter config. The entry is added
with `enabled=false` (never auto-selected) unless the caller passes a
`gate::Dict` (from `LearnEval.promotion_gate`) whose `promote` is true.

`config_path` is injectable so tests can write to a temp file instead of the
real `~/.kamila_models.json`.

Returns a `Dict` with `:registered` (bool) and `:reason`.
"""
function promote_adapter(;
    model_name::String,
    label::String = "Fine-tuned adapter",
    task_type::Symbol = :default,
    priority::Int = 100,
    enabled::Bool = false,
    gate::Union{Nothing,Dict} = nothing,
    config_path::String = ModelRouter.CONFIG_PATH,
)
    # If a gate was supplied, respect it.
    if gate !== nothing
        if !Bool(get(gate, "promote", false))
            return Dict{String,Any}(
                "registered" => false,
                "reason" => string(get(gate, "reason", "gate did not pass")),
            )
        end
    end

    configs = ModelRouter.get_router_config()
    if any(c -> c.name == model_name, configs)
        return Dict{String,Any}(
            "registered" => true,
            "reason" => "already registered",
            "enabled" => enabled,
        )
    end

    cfg = ModelConfig(
        name = model_name,
        label = label,
        task_type = task_type,
        priority = priority,
        max_tokens = 4000,
        temperature = 0.65,
        enabled = enabled,
    )
    push!(configs, cfg)
    open(config_path, "w") do io
        write(io, JSON.json(Dict("models" => [ModelRouter.modelconfig_to_dict(c) for c in configs]), 2))
    end

    KamilaLog.info(
        "tune.promote: registered $model_name (enabled=$enabled)";
        mod = "tune",
    )
    return Dict{String,Any}(
        "registered" => true,
        "reason" => "registered (enabled=$enabled)",
        "enabled" => enabled,
    )
end

"""
    adapter_registered(model_name::String; configs=ModelRouter.get_router_config())

Whether `model_name` is present in the router config.
"""
function adapter_registered(
    model_name::String;
    configs::Vector{ModelConfig} = ModelRouter.get_router_config(),
)
    return any(c -> c.name == model_name, configs)
end

end # module
