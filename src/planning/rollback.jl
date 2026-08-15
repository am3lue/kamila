"""
Rollback — inverse-action registry for verified-failed plan steps (04.3).

When a step's post-condition verification finally fails, the runner asks
Rollback to undo the side effect. Actions are only attempted when the step
declared a reversible operation at execution time (e.g. `write_file` with
`create_backup=true`, or a shell command carrying an `undo_command`). If no
inverse is defined the failure is surfaced to the user instead of silently
continuing.
"""

module Rollback

using Dates
using ..KamilaLog
using ..Errors

export register!, rollback, restore_from_backup, has_rollback

"""
Registry of inverse-action functions keyed by tool name. Each entry maps a tool
name to a function `(args::Dict, workdir::String) -> (ok::Bool, evidence::String)`.
"""
const _INVERSE = Dict{String,Function}()

"""
Register (or replace) the inverse action for a tool.
"""
function register!(tool::String, inverse::Function)
    _INVERSE[tool] = inverse
    return nothing
end

function has_rollback(tool::String)
    return haskey(_INVERSE, tool)
end

function _run_undo_command(args::Dict, workdir::String)
    undo = get(args, "undo_command", "")
    isempty(undo) && return false, "no undo_command provided for shell step"
    ok = false
    out = ""
    try
        out = cd(workdir) do
            read(`timeout 30 bash -c $undo`, String)
        end
        ok = true
    catch e
        ok = false
        out = string(e)
    end
    return ok, ok ? "undo command ran:\n$out" : "undo command failed: $out"
end

"""
Restore `file_path` from its `.bak` (created by `write_file` with
`create_backup=true`). Returns `(ok, evidence)`.
"""
function restore_from_backup(file_path::String)
    backup = file_path * ".bak"
    isfile(backup) || return false, "no backup found for $file_path"
    try
        cp(backup, file_path; force = true)
        return true, "restored $file_path from backup"
    catch e
        return false, "restore failed: $(Errors.error_string(e))"
    end
end

"""
Attempt to roll back the side effect of a failed step's tool call.
Returns `(rolled_back::Bool, evidence::String)`.
"""
function rollback(tool::String, args::AbstractDict, workdir::String)
    if tool == "write_file"
        path = string(get(args, "file_path", ""))
        isempty(path) && return false, "write_file rollback: no file_path"
        if !get(args, "create_backup", false)
            return false, "write_file rollback skipped: create_backup was false"
        end
        ok, evidence = restore_from_backup(path)
        _log("write_file", ok, evidence)
        return ok, evidence
    elseif tool == "run_shell_command"
        ok, evidence = _run_undo_command(args, workdir)
        _log("run_shell_command", ok, evidence)
        return ok, evidence
    elseif haskey(_INVERSE, tool)
        ok, evidence = _INVERSE[tool](args, workdir)
        _log(tool, ok, evidence)
        return ok, evidence
    end
    evidence = "no rollback defined for tool '$tool'; surfacing failure to user"
    KamilaLog.warn("rollback.unavailable"; mod = "rollback", fields = Dict("tool" => tool))
    return false, evidence
end

function _log(tool::String, ok::Bool, evidence::String)
    KamilaLog.info(
        ok ? "rollback.ok" : "rollback.failed";
        mod = "rollback",
        fields = Dict{String,Any}("tool" => tool, "evidence" => evidence),
    )
    return nothing
end

end # module