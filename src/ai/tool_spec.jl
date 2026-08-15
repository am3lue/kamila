"""
ToolSpec — schema-first tool definitions for native function calling (05.1).

Replaces the description-only `Tool.parameters` with real JSON Schemas that are
passed to Ollama's `/api/chat` `tools` array so the model emits structured
`tool_calls` instead of text-JSON the runtime must scrape. Also provides
argument validation and the validated execution path used by the streaming
agent loop.
"""

module ToolSpec

using JSON
using ..Errors
using ..AgentTools
using ..KamilaLog

export ToolSpec, to_json_schema, from_tool, get_tool_specs,
    validate_args, execute_tool_validated, supports_native_tools, to_payload

struct ToolSpec
    name::String
    description::String
    schema::Dict{String,Any}      # JSON Schema (object)
    strict::Bool
end

const TYPE_HINTS = Dict{String,String}(
    "run_shell_command" => "command",
    "read_file" => "file_path",
    "write_file" => "file_path",
    "list_directory" => "path",
    "add_task" => "title",
    "complete_task" => "task_id",
    "web_search" => "query",
    "file_find" => "pattern",
    "grep_search" => "pattern",
    "system_status" => "detail",
    "set_reminder" => "message",
    "memory_query" => "query",
    "decompose_goal" => "goal",
)

"""
Infer a JSON Schema `type` for a parameter from its name + description.
Defaults to string; numeric-looking names (counts, limits, ids, delays) become
integer; boolean words become boolean.
"""
function _infer_type(name::String, description::String)
    d = lowercase(description)
    if occursin(r"\(required\)", d) || occursin("(required)", description)
        # type is independent of required-ness; fall through to name heuristics
    end
    n = lowercase(name)
    if occursin(r"bool|flag|enabled|show_", n) || occursin("true or false", d)
        return "boolean"
    elseif occursin(r"count|number|limit|max_results|delay|minutes|priority|depth|size|max_bytes|start_line|end_line|task_id|timeout", n) ||
           occursin(r"integer|numeric", d)
        return "integer"
    end
    return "string"
end

"""
Convert a `Tool` into a JSON Schema object (draft-07 subset Ollama accepts).
Parameters recorded as `name => description` become `properties`; parameters
whose description says "(required)" are listed in `required`.
"""
function to_json_schema(tool::AgentTools.Tool)
    properties = Dict{String,Any}()
    required = String[]
    for (name, desc) in tool.parameters
        name = String(name)
        desc = String(desc)
        props = Dict{String,Any}(
            "type" => _infer_type(name, desc),
            "description" => desc,
        )
        if occursin("(required)", desc)
            push!(required, name)
        end
        properties[name] = props
    end
    schema = Dict{String,Any}(
        "type" => "object",
        "properties" => properties,
    )
    if !isempty(required)
        schema["required"] = required
    end
    return schema
end

function from_tool(tool::AgentTools.Tool)
    return ToolSpec(tool.name, tool.description, to_json_schema(tool), true)
end

"""
Serialize a ToolSpec into the Ollama `/api/chat` tools-array element shape:
    {"type": "function", "function": {"name", "description", "parameters"}}
"""
function to_payload(spec::ToolSpec)
    return Dict{String,Any}(
        "type" => "function",
        "function" => Dict{String,Any}(
            "name" => spec.name,
            "description" => spec.description,
            "parameters" => spec.schema,
        ),
    )
end

"""
Build the `tools` array for the Ollama `/api/chat` payload from all registered
tools.
"""
function get_tool_specs()
    return [from_tool(t) for t in AgentTools.get_all_tools()]
end

"""
Native tool-support detection. `capabilities` is an array of capability names
(e.g. `["tools"]` from `get_model_info`). Defaults to true for models that
advertise tool support or use the built-in Kamila models.
"""
function supports_native_tools(name::String; capabilities = nothing)
    if name in ("kamila1", "kamila2", "kamila:latest")
        return false   # built-in text models do not advertise tool calling
    end
    if capabilities !== nothing
        return "tools" in capabilities
    end
    return false
end

supports_native_tools(name::String, caps::AbstractVector) =
    supports_native_tools(name; capabilities = caps)

# ─── Validation ───────────────────────────────────────────

"""
Validate `args` against a JSON Schema (object). Returns `(ok, errors::Vector{String})`.
Supports `type` (string/integer/number/boolean), `required`, and `properties`.
Unknown extra keys are allowed (lenient) to match model behavior.
"""
function validate_args(schema::Dict{String,Any}, args::AbstractDict)
    errors = String[]
    props = get(schema, "properties", Dict{String,Any}())
    required = get(schema, "required", Any[])

    for name in required
        if !haskey(args, name)
            push!(errors, "missing required argument: $name")
        end
    end

    for (name, value) in args
        name = String(name)
        haskey(props, name) || continue
        spec = props[name]
        typ = get(spec, "type", "string")
        ok = _check_type(typ, value)
        if !ok
            push!(errors, "argument '$name' expected $typ, got $(typeof(value))")
        end
    end
    return isempty(errors), errors
end

function _check_type(typ::String, value)
    if typ == "string"
        return value isa AbstractString
    elseif typ == "integer"
        return value isa Integer
    elseif typ == "number"
        return value isa Real
    elseif typ == "boolean"
        return value isa Bool
    end
    return true
end

"""
Execute a tool with schema validation. Invalid args produce a `:validation`
error result (never throws) so the model can recover.
"""
function execute_tool_validated(name::String, args::AbstractDict, spec::ToolSpec)
    ok, errors = validate_args(spec.schema, args)
    if !ok
        msg = "Tool '$name' argument validation failed: " * join(errors, "; ")
        KamilaLog.warn(
            "tool.validation.failed";
            mod = "toolspec",
            fields = Dict("tool" => name, "errors" => errors),
        )
        return Dict{String,Any}(
            "ok" => false,
            "category" => "validation",
            "retryable" => true,
            "result" => msg,
        )
    end
    return AgentTools.execute_tool_structured(name, Dict{String,Any}(args))
end

execute_tool_validated(name::String, args::AbstractDict) = begin
    specs = get_tool_specs()
    found = findfirst(s -> s.name == name, specs)
    found === nothing && throw(
        Errors.KamilaError(:notfound, "no tool spec for '$name'"),
    )
    return execute_tool_validated(name, args, specs[found])
end

end # module