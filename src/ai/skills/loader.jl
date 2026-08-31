"""
Skills — skill registry (05.2).

Makes skills first-class, persistent, versioned, and runtime-growable. Built-in
skills (the 13 core tools) are seeded from source into the SQLite registry at
init; installed skills are user/agent-added records. The loader resolves each
record's `impl_type` (julia/shell/prompt/delegated) into a callable, and
`AgentTools.get_all_tools()`/`execute_tool` derive from this registry instead of
a hardcoded list.

Registry-backed tools are exposed through `register_tool_source!`, which swaps
`AgentTools`' tool list at init. Skill records live in the `skills` table
(schema v5).
"""

module Skills

using Dates
using JSON
using ..MemoryDB
using ..KamilaLog
using ..Errors
using ..Permission
import ..ToolSpec: to_json_schema
import ..AgentTools

export Skill,
    seed_builtins!,
    load_all,
    get_skill,
    install!,
    uninstall!,
    enable!,
    disable!,
    list,
    show_skill,
    learn_skill,
    register_tool_source!,
    skill_to_tool,
    load_user_skills!,
    register_skill,
    _skill_fields

const MAX_SKILLS = 100
const MAX_SPEC_SIZE = 16 * 1024

struct Skill
    id::String
    name::String
    version::String
    spec::Dict{String,Any}          # ToolSpec-compatible JSON schema
    description::String
    impl_type::String               # :julia | :shell | :prompt | :delegated
    impl_ref::String
    enabled::Bool
    source::String                  # builtin | user | agent
end

# ─── Row ⇄ struct ─────────────────────────────────────────

function _skill_fields(row::NamedTuple)
    return (
        id = string(get(row, :id, "")),
        name = string(get(row, :name, "")),
        version = string(get(row, :version, "1.0.0")),
        spec = _parse_spec(get(row, :spec, "{}")),
        description = string(get(row, :description, "")),
        impl_type = string(get(row, :impl_type, "julia")),
        impl_ref = string(get(row, :impl_ref, "")),
        enabled = Int(get(row, :enabled, 1)) == 1,
        source = string(get(row, :source, "user")),
    )
end

function _parse_spec(raw)
    try
        d = JSON.parse(raw)
        return d isa AbstractDict ?
               Dict{String,Any}(String(k) => v for (k, v) in d) :
               Dict{String,Any}()
    catch
        return Dict{String,Any}()
    end
end

# ─── Seeding ──────────────────────────────────────────────

const _SEEDED = Ref(false)

"""
Seed the 13 built-in skills from `AgentTools._CORE_TOOLS()`. Idempotent:
re-seeding a built-in (version bump) refreshes its spec while preserving the
`enabled` flag and the `source="builtin"` marker.
"""
function seed_builtins!()
    # A process-global flag is not enough: the DB may be reset between sessions
    # (in-memory DBs in tests), which would leave the skills table empty while
    # `_SEEDED` is still true. Re-seed whenever the table has no rows.
    if _SEEDED[]
        rows = MemoryDB.query_all("SELECT 1 FROM skills LIMIT 1")
        isempty(rows) || return nothing
    end
    _SEEDED[] = true
    now_s = string(now())
    for tool in AgentTools._CORE_TOOLS()
        spec = to_json_schema(tool)
        existing = _db_get(tool.name)
        if existing === nothing
            _db_insert(
                tool.name,
                tool.name,
                "1.0.0",
                spec,
                tool.description,
                "julia",
                tool.name,
                1,
                "builtin",
                now_s,
            )
        else
            _db_update_spec(tool.name, spec, tool.description)
        end
    end
    return nothing
end

# ─── Queries ──────────────────────────────────────────────

function _db_get(name::String)
    rows = MemoryDB.query_all(
        "SELECT * FROM skills WHERE name = ? LIMIT 1",
        name,
    )
    isempty(rows) && return nothing
    return _skill_fields(first(rows))
end

function load_all()
    seed_builtins!()
    load_user_skills!()
    rows = MemoryDB.query_all("SELECT * FROM skills ORDER BY name")
    return [_skill_fields(r) for r in rows]
end

function list()
    return [
        Dict{String,Any}(
            "id" => s.id,
            "name" => s.name,
            "version" => s.version,
            "description" => s.description,
            "impl_type" => s.impl_type,
            "enabled" => s.enabled,
            "source" => s.source,
        ) for s in load_all()
    ]
end

function get_skill(name::String)
    row = _db_get(name)
    row === nothing && return nothing
    return Skill(
        row.id, row.name, row.version, row.spec, row.description,
        row.impl_type, row.impl_ref, row.enabled, row.source,
    )
end

function show_skill(name::String)
    s = get_skill(name)
    s === nothing && throw(Errors.KamilaError(:notfound, "skill '$name' not found"))
    return Dict{String,Any}(
        "id" => s.id,
        "name" => s.name,
        "version" => s.version,
        "description" => s.description,
        "impl_type" => s.impl_type,
        "impl_ref" => s.impl_ref,
        "enabled" => s.enabled,
        "source" => s.source,
        "spec" => s.spec,
    )
end

# ─── Persistence helpers ──────────────────────────────────

function _db_insert(id, name, version, spec, description, impl_type, impl_ref, enabled, source, now_s)
    MemoryDB.execute!(
        """
        INSERT OR REPLACE INTO skills
            (id, name, version, spec, description, impl_type, impl_ref,
             enabled, source, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (id, name, version, JSON.json(spec), description, impl_type, impl_ref,
            Int(enabled), source, now_s, now_s),
    )
end

function _db_update_spec(name, spec, description)
    MemoryDB.execute!(
        "UPDATE skills SET spec = ?, description = ?, updated_at = ? WHERE name = ?",
        (JSON.json(spec), description, string(now()), name),
    )
end

# ─── Install / uninstall / enable / disable ───────────────

"""
Install a skill from a JSON spec dict:
    {name, description, parameters (JSON Schema), version?,
     impl_type? (julia|shell|prompt|delegated), impl_ref?, source?}
Built-ins cannot be replaced; new records default to `enabled=true` for user
installs and `enabled=false` for agent-registered skills.
"""
function install!(spec_dict::AbstractDict; source::String = "user", enabled::Bool = true)
    name = string(get(spec_dict, "name", ""))
    isempty(name) && throw(Errors.KamilaError(:validation, "skill name is required"))
    n = length(load_all())
    n >= MAX_SKILLS && throw(Errors.KamilaError(:validation, "max skills ($MAX_SKILLS) reached"))

    spec_raw = get(spec_dict, "parameters", get(spec_dict, "spec", Dict()))
    spec = spec_raw isa Dict ? Dict{String,Any}(spec_raw) : Dict{String,Any}()
    isempty(spec) && (spec = Dict{String,Any}("type" => "object", "properties" => Dict{String,Any}()))
    # 05.3: persist declared `required_capabilities` inside the stored spec so
    # `enable!`/`install!` can gate on them across re-loads.
    declared_caps = get(spec_dict, "required_capabilities", nothing)
    if declared_caps !== nothing
        spec["required_capabilities"] = declared_caps
    end
    spec_bytes = length(JSON.json(spec))
    spec_bytes > MAX_SPEC_SIZE &&
        throw(Errors.KamilaError(:validation, "skill spec exceeds $MAX_SPEC_SIZE bytes"))

    impl_type = string(get(spec_dict, "impl_type", "julia"))
    impl_ref = string(get(spec_dict, "impl_ref", ""))
    description = string(get(spec_dict, "description", ""))
    version = string(get(spec_dict, "version", "1.0.0"))
    source = string(get(spec_dict, "source", source))

    # 05.3: installing a skill as enabled requires its declared capabilities to
    # be granted. Installing disabled (e.g. agent-registered) is always allowed;
    # `enable!` re-checks before flipping it on.
    if enabled
        required = _required_caps_of(spec)
        missing = [cap for cap in required if !Permission.granted_cap(cap)]
        if !isempty(missing)
            throw(
                Errors.KamilaError(
                    :permission,
                    "skill '$name' requires un-granted capabilities: $(join(missing, ", "))",
                    details = Dict("skill" => name, "missing" => missing),
                ),
            )
        end
    end

    existing = _db_get(name)
    if existing !== nothing
        existing.source == "builtin" &&
            throw(Errors.KamilaError(:validation, "built-in skill '$name' cannot be replaced"))
        # Re-installing an existing non-builtin skill: bump version, keep the
        # existing enabled state and source (a pending agent skill stays disabled
        # until the user approves; a disabled user skill stays disabled).
        _db_insert(
            name, name, version, spec, description, impl_type, impl_ref,
            existing.enabled ? 1 : 0, existing.source, string(now()),
        )
        return get_skill(name)
    end

    _db_insert(
        name, name, version, spec, description, impl_type, impl_ref,
        Int(enabled), source, string(now()),
    )
    return get_skill(name)
end

function uninstall!(name::String)
    existing = _db_get(name)
    existing === nothing && throw(Errors.KamilaError(:notfound, "skill '$name' not found"))
    existing.source == "builtin" &&
        throw(Errors.KamilaError(:validation, "built-in skill '$name' cannot be uninstalled"))
    MemoryDB.execute!("DELETE FROM skills WHERE name = ?", name)
    return nothing
end

function enable!(name::String)
    existing = _db_get(name)
    existing === nothing && throw(Errors.KamilaError(:notfound, "skill '$name' not found"))
    # 05.3: a skill that declares `required_capabilities` may only be enabled when
    # those capabilities are granted by the policy.
    required = _required_caps_of(existing.spec)
    missing = [cap for cap in required if !Permission.granted_cap(cap)]
    if !isempty(missing)
        throw(
            Errors.KamilaError(
                :permission,
                "skill '$name' requires un-granted capabilities: $(join(missing, ", "))",
                details = Dict("skill" => name, "missing" => missing),
            ),
        )
    end
    MemoryDB.execute!("UPDATE skills SET enabled = 1, updated_at = ? WHERE name = ?", (string(now()), name))
    return nothing
end

function disable!(name::String)
    existing = _db_get(name)
    existing === nothing && throw(Errors.KamilaError(:notfound, "skill '$name' not found"))
    MemoryDB.execute!("UPDATE skills SET enabled = 0, updated_at = ? WHERE name = ?", (string(now()), name))
    return nothing
end

# ─── learn_skill (agent self-registration) ────────────────

"""
Agent-driven skill registration. Captures a reusable procedure as a `:prompt`
or `:shell` skill. Stored with `enabled=false` and `source="agent"` until a
user approves (05.3 gates the tool call at `:ask`).
"""
function learn_skill(args::Dict)
    name = string(get(args, "name", ""))
    procedure = string(get(args, "procedure", ""))
    impl_type = string(get(args, "impl_type", "prompt"))
    parameters = get(args, "parameters", Dict{String,Any}())

    isempty(name) && return Dict{String,Any}(
        "ok" => false, "category" => "validation", "retryable" => true,
        "result" => "learn_skill requires a 'name'",
    )
    isempty(procedure) && return Dict{String,Any}(
        "ok" => false, "category" => "validation", "retryable" => true,
        "result" => "learn_skill requires a 'procedure'",
    )
    impl_type in ("prompt", "shell") || return Dict{String,Any}(
        "ok" => false, "category" => "validation", "retryable" => true,
        "result" => "impl_type must be 'prompt' or 'shell'",
    )
    length(procedure) > 4096 && return Dict{String,Any}(
        "ok" => false, "category" => "validation", "retryable" => true,
        "result" => "procedure too long (max 4096 chars)",
    )

    spec = Dict{String,Any}(
        "type" => "object",
        "properties" => parameters isa Dict ? parameters : Dict{String,Any}(),
    )
    try
        install!(
            Dict{String,Any}(
                "name" => name,
                "description" => "Agent-registered $impl_type skill",
                "parameters" => spec,
                "impl_type" => impl_type,
                "impl_ref" => procedure,
                "version" => "1.0.0",
            );
            source = "agent",
            enabled = false,
        )
        return Dict{String,Any}(
            "ok" => true,
            "category" => "success",
            "result" => "Skill '$name' registered (enabled=false, awaiting approval)",
        )
    catch e
        return Dict{String,Any}(
            "ok" => false, "category" => "internal", "retryable" => true,
            "result" => "learn_skill failed: $(Errors.error_string(e))",
        )
    end
end

# ─── User-dir skills ──────────────────────────────────────

const USER_SKILLS_DIR = Ref{String}(
    get(ENV, "KAMILA_SKILLS_DIR", joinpath(homedir(), ".config", "kamila", "skills")),
)

"""
Scan `~/.config/kamila/skills/*.jl` for user Julia skills. Each file may call
`register_skill(spec, impl)` (defined below); the callbacks accumulate into a
local registry that is then installed into the DB (source="user", enabled=true).
Bad files are caught and skipped, never aborting the process.
"""
const _USER_REGISTRATIONS = Ref{Vector{Dict{String,Any}}}(Dict{String,Any}[])
const _USER_LOADED = Ref(false)

function register_skill(spec::AbstractDict, impl::Function)
    d = Dict{String,Any}(String(k) => v for (k, v) in spec)
    d["impl_ref"] = string(d["impl_ref"])
    d["_impl"] = impl
    push!(_USER_REGISTRATIONS[], d)
    return nothing
end

function load_user_skills!()
    _USER_LOADED[] && return nothing
    _USER_LOADED[] = true
    dir::String = USER_SKILLS_DIR[]
    isdir(dir) || return nothing

    # Sandboxed module for user code: bad files must not abort the process.
    mod = Module(:UserSkillsSandbox)
    Core.eval(mod, :(include = Base.include))
    Core.eval(
        mod,
        :(register_skill = $register_skill),
    )

    for file in sort(readdir(dir))
        endswith(file, ".jl") || continue
        try
            Base.include(mod, joinpath(dir, file))
        catch e
            KamilaLog.warn(
                "skills.user_file_failed";
                mod = "skills",
                fields = Dict("file" => file, "error" => string(e)),
            )
        end
    end

    for d in _USER_REGISTRATIONS[]
        name = string(get(d, "name", ""))
        isempty(name) && continue
        try
            spec = Dict{String,Any}(
                "name" => name,
                "description" => string(get(d, "description", "")),
                "parameters" => get(d, "parameters", Dict{String,Any}()),
                "impl_type" => string(get(d, "impl_type", "julia")),
                "impl_ref" => string(get(d, "impl_ref", name)),
                "version" => string(get(d, "version", "1.0.0")),
            )
            install!(spec; source = "user", enabled = true)
        catch e
            KamilaLog.warn(
                "skills.user_install_failed";
                mod = "skills",
                fields = Dict("name" => name, "error" => string(e)),
            )
        end
    end
    empty!(_USER_REGISTRATIONS[])
    return nothing
end

# ─── Skill → AgentTools.Tool ──────────────────────────────

"""
Build an `AgentTools.Tool` from a skill record, resolving its implementation.
- :julia → the built-in core function (matched by name); unknown refs fall back
  to a not-implemented stub.
- :shell → runs the command template with `{input}` interpolation.
- :prompt → returns the stored procedure as the "result" (a doc/explanatory
  skill; execution-time model call is delegated by the caller).
"""
function skill_to_tool(s::Skill)
    if s.impl_type == "julia"
        core = [t for t in AgentTools._CORE_TOOLS() if t.name == s.name]
        if !isempty(core)
            return AgentTools.Tool(s.name, s.description, _params_of(s.spec), first(core).func)
        end
        return AgentTools.Tool(
            s.name, s.description, _params_of(s.spec),
            (_args) -> "skill '$s.name': julia impl_ref '$(s.impl_ref)' not resolvable",
        )
    elseif s.impl_type == "shell"
        template = s.impl_ref
        return AgentTools.Tool(
            s.name, s.description, _params_of(s.spec),
            (_args) -> _run_shell_skill(s.name, template, _args),
        )
    else
        # :prompt / :delegated — returns the stored procedure.
        return AgentTools.Tool(
            s.name, s.description, _params_of(s.spec),
            (_args) -> s.impl_ref,
        )
    end
end

function _params_of(spec::Dict{String,Any})
    props = get(spec, "properties", Dict{String,Any}())
    params = Dict{String,String}()
    for (k, v) in props
        params[String(k)] = string(get(v, "description", ""))
    end
    return params
end

"""
Read the `required_capabilities` list a skill declares (05.3). Defaults to the
skill's implied capability: a `:shell` skill requires `"shell"`, everything else
requires nothing by default.
"""
function _required_caps_of(spec::Dict{String,Any})
    declared = get(spec, "required_capabilities", Any[])
    caps = String[]
    for c in declared
        push!(caps, string(c))
    end
    return caps
end

# Dangerous command prefixes that shell skills must never run, even with a
# valid {input} template (05.3 permission model treats these as deny-by-default).
const FORBIDDEN_SHELL_PREFIXES = [
    "rm ", "rm -", "rmdir ", "mv ", "dd ", "mkfs", "fdisk", "parted",
    "chmod -R", "chown -R", "sudo ", "shutdown", "reboot", "kill ",
    ":(){", "mkinitrd", "grub", "fstrim /", "wipefs", "shred ",
]

function _run_shell_skill(name::String, template::String, args::Dict)
    # Template allowlist: only {input} interpolation is permitted; anything else
    # (e.g. {command}) is rejected to prevent shell-injection via spec fields.
    occursin(r"\{[^}]*\}", template) || return "Error [validation] skill '$name' template has no {input} placeholder"
    input = string(get(args, "input", ""))
    isempty(input) && return "Error [validation] skill '$name' requires an 'input' argument"
    command = replace(template, "{input}" => input)
    # Only the single {input} token is allowed.
    if occursin(r"\{[^}]*\}", command)
        return "Error [validation] skill '$name' template may only interpolate {input}"
    end
    # Dangerous-command blocklist (defense in depth; enforced by 05.3 too).
    stripped = lstrip(command)
    for prefix in FORBIDDEN_SHELL_PREFIXES
        if startswith(stripped, prefix)
            return "Error [validation] skill '$name' uses forbidden command prefix '$prefix'"
        end
    end
    try
        return AgentTools._run_shell_for_skill(command)
    catch e
        return "Error executing skill '$name': $(Errors.error_string(e))"
    end
end

# ─── Registry-backed tool source ──────────────────────────

"""
Swap `AgentTools.get_all_tools()` to derive from this registry. Enabled skills
become `Tool`s; disabled skills are excluded. Returns nothing.
"""
function register_tool_source!()
    AgentTools.register_tool_source!(_registry_tools)
    return nothing
end

function _registry_tools()
    seed_builtins!()
    load_user_skills!()
    tools = AgentTools.Tool[]
    for row in load_all()
        s = Skill(
            row.id, row.name, row.version, row.spec, row.description,
            row.impl_type, row.impl_ref, row.enabled, row.source,
        )
        s.enabled && push!(tools, skill_to_tool(s))
    end
    return vcat(tools, AgentTools._EXTRA_TOOLS[])
end

# ─── learn_skill tool registration (05.2) ─────────────────
# Registered as an extra tool at module load (same pattern as `batch`), so it
# appears in every tool list once the Skills module is loaded.

AgentTools.register_tool!(
    AgentTools.Tool(
        "learn_skill",
        "Register a reusable procedure as a new skill. The skill is stored with enabled=false (source=agent) until a user approves it. Use impl_type 'prompt' (a text procedure) or 'shell' (a command template with exactly one {input} placeholder). Args: {\"name\": str, \"procedure\": str, \"impl_type\": \"prompt\"|\"shell\", \"params\": {param_name: {type, description}} (optional)}",
        Dict(
            "name" => "Skill name (required)",
            "procedure" => "The reusable procedure or shell command template (required)",
            "impl_type" => "prompt or shell (default: prompt)",
            "params" => "Optional JSON Schema properties for the skill",
        ),
        learn_skill,
    ),
)

end # module