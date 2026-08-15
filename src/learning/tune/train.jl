"""
TuneTrain — wrap `ollama create` with a LoRA adapter Modelfile (07.2).

Builds a Modelfile (`FROM <small local base>` + `ADAPTER <lora>` + reused
`PARAMETER`s) and invokes `ollama create <model> -f <modelfile>`. The primary
model is never mutated: the fine-tuned model is a brand-new name, and the job
defaults to `dry_run=true` so nothing is touched until the caller explicitly
runs it.
"""

module TuneTrain

using JSON
using ..KamilaLog

export build_modelfile, train, DEFAULT_FINE_TUNE_BASE

const DEFAULT_FINE_TUNE_BASE = "qwen2.5-coder:0.5b"

# Standard Kamila inference parameters (mirror config/Modelfile where sane).
const DEFAULT_PARAMS = Dict{String,Any}(
    "temperature" => 0.65,
    "top_p" => 0.9,
    "frequency_penalty" => 0.3,
)

"""
    build_modelfile(; base, adapter_path, params=DEFAULT_PARAMS)

Render a Modelfile that layers a LoRA adapter over a small local base model.
The adapter path is a filesystem path to the `.gguf` LoRA file.
"""
function build_modelfile(
    adapter_path::String;
    base::String = DEFAULT_FINE_TUNE_BASE,
    params::Dict{String,Any} = DEFAULT_PARAMS,
    system::String = "",
)
    lines = String["FROM $base", "ADAPTER $adapter_path"]
    for (k, v) in params
        push!(lines, "PARAMETER $k $v")
    end
    if !isempty(system)
        push!(lines, "SYSTEM \"\"\"$system\"\"\"")
    end
    return join(lines, "\n") * "\n"
end

"""
    train(; model_name, dataset_path, adapter_path, base=DEFAULT_FINE_TUNE_BASE,
          modelfile_path, dry_run=true, params=DEFAULT_PARAMS)

Run a fine-tune job for a NEW model named `model_name` using a LoRA adapter
and a dataset (used for bookkeeping/logging; actual training happens in
Ollama). Writes the Modelfile and, when `dry_run=false`, invokes
`ollama create <model_name> -f <modelfile>`.

Returns a Dict:
- `:dry_run`   true when only the command was prepared
- `:command`   the shell command that would run
- `:ok`        exit success when actually run
- `:model_name` the new model name
"""
function train(;
    model_name::String,
    dataset_path::String,
    adapter_path::String,
    base::String = DEFAULT_FINE_TUNE_BASE,
    modelfile_path::String = "",
    dry_run::Bool = true,
    params::Dict{String,Any} = DEFAULT_PARAMS,
)
    isempty(strip(model_name)) && Base.error("model_name is required")
    startswith(model_name, base) && Base.error("model_name must differ from base model")

    mpath = isempty(modelfile_path) ? tempname() * ".Modelfile" : modelfile_path
    open(mpath, "w") do io
        write(io, build_modelfile(adapter_path; base = base, params = params))
    end

    cmd = "ollama create $model_name -f $mpath"

    if dry_run
        KamilaLog.info(
            "tune.train(dry_run): $cmd (dataset=$dataset_path, adapter=$adapter_path)";
            mod = "tune",
        )
        return Dict{String,Any}(
            "dry_run" => true,
            "command" => cmd,
            "ok" => false,
            "model_name" => model_name,
            "modelfile" => mpath,
        )
    end

    code = try
        run(ignorestatus(Cmd(cmd))).exitcode
    catch e
        KamilaLog.warn("tune.train.failed: $e"; mod = "tune")
        -1
    end

    return Dict{String,Any}(
        "dry_run" => false,
        "command" => cmd,
        "ok" => code == 0,
        "exit_code" => code,
        "model_name" => model_name,
        "modelfile" => mpath,
    )
end

end # module
