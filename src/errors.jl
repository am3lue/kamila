"""
Errors — typed error taxonomy for Kamila.

Replaces "everything is a string" error handling with a categorized model so
tools, the bridge, and the TUI can react appropriately (retry vs. deny vs.
user-fix vs. fatal). Every category maps to an HTTP-ish status code and a
retryability flag; the bridge carries both in `error` events and the agent
loop uses them to decide whether a failing step is worth retrying.

Categories:
  :permission   - denied by policy / auth (403, not retryable)
  :validation   - bad arguments / malformed input (400, not retryable)
  :notfound     - file/task/resource missing (404, not retryable)
  :timeout      - operation exceeded its time budget (504, retryable)
  :network      - transport-level failure (503, retryable)
  :external     - downstream service error (502, retryable)
  :model        - LLM/model failure (502, retryable)
  :internal     - unexpected bug in Kamila (500, not retryable)
  :unsupported  - feature not available here (501, not retryable)
"""

module Errors

using JSON
using ..KamilaLog

export KamilaError,
    CATEGORIES, is_retryable, http_status, error_category, error_string, category_name

const CATEGORIES = [
    :permission,
    :validation,
    :notfound,
    :timeout,
    :network,
    :external,
    :model,
    :internal,
    :unsupported,
]

const _RETRYABLE = Set([:timeout, :network, :external, :model])
const _HTTP_STATUS = Dict(
    :permission => 403,
    :validation => 400,
    :notfound => 404,
    :timeout => 504,
    :network => 503,
    :external => 502,
    :model => 502,
    :internal => 500,
    :unsupported => 501,
)

"""
A categorized Kamila error.

Fields:
  category::Symbol  one of [`CATEGORIES`](@ref)
  message::String   human-readable description
  code::Int         optional extra code (defaults to the category's HTTP status)
  retryable::Bool   whether a retry could plausibly succeed
  details::Dict     optional structured context (path, tool, model, ...)
"""
struct KamilaError <: Exception
    category::Symbol
    message::String
    code::Int
    retryable::Bool
    details::Dict{String,Any}
end

KamilaError(
    category::Symbol,
    message::AbstractString;
    code::Int = -1,
    retryable::Bool = false,
    details = Dict{String,Any}(),
) = KamilaError(
    category,
    String(message),
    code < 0 ? http_status(category) : code,
    retryable || category in _RETRYABLE,
    Dict{String,Any}(details),
)

Base.showerror(io::IO, e::KamilaError) =
    print(io, category_name(e.category), " error: ", e.message)

category_name(category::Symbol) = String(category)

"""
Whether an error (KamilaError or generic) is safe to retry.
"""
is_retryable(e::KamilaError) = e.retryable
is_retryable(e::Exception) = false
is_retryable(e) = false

"""
HTTP-style status for a category (or an error).
"""
http_status(e::KamilaError) = e.code
http_status(category::Symbol) = get(_HTTP_STATUS, category, 500)

"""
Extract the category Symbol from any error; `:internal` for unknown exceptions.
"""
error_category(e::KamilaError) = e.category
error_category(e::Exception) = :internal
error_category(e) = :internal

"""
Format any error for a tool's string return path. KamilaError produces a rich,
category-tagged line; anything else degrades to a plain message.
"""
function error_string(e::KamilaError)
    detail = isempty(e.details) ? "" : " " * JSON.json(e.details)
    cat = category_name(e.category)
    "Error [$cat] $(e.message)$detail"
end

function error_string(e)
    s = string(e)
    isempty(s) && (s = "unknown error")
    s
end

"""
Build the structured payload used by `execute_tool_structured` and the bridge.
"""
function error_payload(e::KamilaError)
    Dict{String,Any}(
        "ok" => false,
        "category" => category_name(e.category),
        "message" => e.message,
        "code" => e.code,
        "retryable" => e.retryable,
        "details" => e.details,
    )
end

function error_payload(e)
    Dict{String,Any}(
        "ok" => false,
        "category" => category_name(error_category(e)),
        "message" => string(e),
        "code" => http_status(error_category(e)),
        "retryable" => false,
        "details" => Dict{String,Any}(),
    )
end

"""
Log an error through KamilaLog at the appropriate level (warn for retryable,
error otherwise) with category/module fields.
"""
function log_error(e::KamilaError; mod::String = "kamila")
    fields = Dict{String,Any}("category" => category_name(e.category), "code" => e.code)
    isempty(e.details) || (fields["details"] = e.details)
    if is_retryable(e)
        KamilaLog.warn(e.message; mod = mod, fields = fields)
    else
        KamilaLog.error(e.message; mod = mod, fields = fields)
    end
    return nothing
end

end # module Errors
