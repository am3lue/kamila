"""
OllamaMockServer — a minimal in-process HTTP server that mimics the Ollama API
enough for Kamila's bridge/agent integration tests.

Why not HTTP.jl's server? `HTTP.listen` starves the event loop when the client
(production code's `curl` subprocess) shares a thread with the server in this
environment. A tiny `Sockets`-based server runs in its own `@async` task and
blocks only its own task on `accept`, which keeps the main test flow responsive.

Protocol implemented:
  - GET  /api/tags    -> {"models": [{...}]} (for connection/model checks)
  - POST /api/generate -> NDJSON streaming lines, one JSON object per line
  - POST /api/chat     -> NDJSON streaming lines with a "message" field

The responses are canned and configurable per test via `set_script!`.
"""

module OllamaMockServer

using Sockets
import Sockets: TCPServer, listen, accept, getsockname, ip, isopen, close
using JSON
using Dates

export start_mock_server,
    stop_mock_server,
    server_port,
    set_script!,
    set_chat_scripts!,
    reset_chat_request_count!,
    chat_line,
    chat_line_thinking,
    generate_line

export last_chat_request, last_chat_has_tools, chat_line_tool_call

mutable struct MockServer
    server::TCPServer
    port::UInt16
    task::Task
    script_lock::ReentrantLock
    generate_lines::Vector{String}   # NDJSON lines for /api/generate
    chat_lines::Vector{String}       # NDJSON lines for /api/chat
    tags_json::String                # body for /api/tags
    request_count::Base.RefValue{Int}
    chat_request_count::Base.RefValue{Int}
    chat_scripts::Vector{Vector{String}}  # optional per-request NDJSON scripts
    last_chat_body::Base.RefValue{String} # body of the most recent /api/chat request
    last_chat_has_tools::Base.RefValue{Bool} # whether the payload included a tools array
end

"""
Create a canned NDJSON line for /api/generate.
"""
function generate_line(; response::String = "", done::Bool = false)
    return JSON.json(
        Dict("model" => "kamila:latest", "response" => response, "done" => done),
    )
end

"""
Create a canned NDJSON line for /api/chat.
"""
function chat_line(; content::String = "", done::Bool = false)
    return JSON.json(
        Dict(
            "model" => "kamila1",
            "message" => Dict("role" => "assistant", "content" => content),
            "done" => done,
        ),
    )
end

"""
Create a canned NDJSON line for /api/chat that includes reasoning ("thinking").
Used to verify the thinking-display path: `message.thinking` must be relayed
separately and excluded from the final answer.
"""
function chat_line_thinking(;
    thinking::String = "",
    content::String = "",
    done::Bool = false,
)
    msg = Dict{String,Any}("role" => "assistant", "content" => content)
    if !isempty(thinking)
        msg["thinking"] = thinking
    end
    return JSON.json(Dict("model" => "kamila1", "message" => msg, "done" => done))
end

"""
Create a canned NDJSON line for /api/chat that includes a native tool call.
`arguments` is a Dict serialized as the function's arguments string.
"""
function chat_line_tool_call(; name::String = "", arguments::Dict = Dict(), done::Bool = true)
    return JSON.json(
        Dict(
            "model" => "kamila1",
            "message" => Dict(
                "role" => "assistant",
                "content" => "",
                "tool_calls" => [
                    Dict(
                        "function" => Dict(
                            "name" => name,
                            "arguments" => JSON.json(arguments),
                        ),
                    ),
                ],
            ),
            "done" => done,
        ),
    )
end

"""
Start a mock Ollama server on 127.0.0.1 with an ephemeral port.
Returns a `MockServer`. Default script: one short /api/chat response.
"""
function start_mock_server(;
    tags_json::String = "{\"models\":[{\"name\":\"kamila1\",\"size\":100,\"details\":{\"parameter_size\":\"1B\"}},{\"name\":\"kamila2\",\"size\":100,\"details\":{\"parameter_size\":\"8B\"}}]}",
)
    server = listen(ip"127.0.0.1", 0)
    port = getsockname(server)[2]

    mock = MockServer(
        server,
        port,
        Task(() -> nothing),
        ReentrantLock(),
        [generate_line(response = "mock generate reply", done = true)],
        [chat_line(content = "mock chat reply", done = true)],
        tags_json,
        Ref(0),
        Ref(0),
        Vector{Vector{String}}(),
        Ref(""),
        Ref(false),
    )

    mock.task = @async begin
        while isopen(server)
            sock = try
                accept(server)
            catch
                break
            end
            @async handle_connection(mock, sock)
        end
    end

    return mock
end

function stop_mock_server(mock::MockServer)
    try
        close(mock.server)
    catch
    end
end

function server_port(mock::MockServer)
    return Int(mock.port)
end

"""
Return the body of the most recent /api/chat request (empty string if none yet).
Used to assert on the messages actually sent to the model (e.g. system prompt).
"""
function last_chat_request(mock::MockServer)
    return mock.last_chat_body[]
end

"""
Return whether the most recent /api/chat payload included a `tools` array.
"""
function last_chat_has_tools(mock::MockServer)
    return mock.last_chat_has_tools[]
end

"""
Set the canned script lines served by the mock.
  - generate_lines: Vector{String}, each element is one NDJSON line.
  - chat_lines: same for /api/chat.
Passing `nothing` leaves the current script unchanged.
"""
function set_script!(mock::MockServer; generate_lines = nothing, chat_lines = nothing)
    lock(mock.script_lock) do
        generate_lines !== nothing && (mock.generate_lines = generate_lines)
        chat_lines !== nothing && (mock.chat_lines = chat_lines)
        # A fixed script supersedes any leftover per-request `chat_scripts`
        # sequence (which would otherwise take priority and leak across tests
        # that share one mock server).
        if chat_lines !== nothing
            empty!(mock.chat_scripts)
            mock.chat_request_count[] = 0
        end
    end
    return mock
end

"""
Set a sequence of /api/chat scripts. Each element is a Vector of NDJSON lines;
the i-th chat request serves the i-th script. Clears any previous sequence.
"""
function set_chat_scripts!(mock::MockServer, scripts::Vector{Vector{String}})
    lock(mock.script_lock) do
        mock.chat_scripts = scripts
    end
    return mock
end

"""
Reset the per-request chat script counter so the next chat request serves
scripts[1] again. Call before a scripted sequence to make it deterministic.
"""
function reset_chat_request_count!(mock::MockServer)
    lock(mock.script_lock) do
        mock.chat_request_count[] = 0
    end
    return mock
end

# ─── Connection handling ─────────────────────────────────

function handle_connection(mock::MockServer, sock)
    try
        request_line, headers, body = read_http_request(sock)
        isempty(request_line) && return

        method, target = parse_request_line(request_line)
        mock.request_count[] += 1

        status_line = "HTTP/1.1 200 OK\r\n"
        if target == "/api/tags"
            payload = mock.tags_json
        elseif startswith(target, "/api/chat")
            mock.last_chat_body[] = body
            try
                parsed = JSON.parse(body)
                mock.last_chat_has_tools[] = haskey(parsed, "tools") &&
                                             !isempty(get(parsed, "tools", Any[]))
            catch
                mock.last_chat_has_tools[] = false
            end
            lock(mock.script_lock) do
                if !isempty(mock.chat_scripts)
                    n = mock.chat_request_count[] + 1
                    script = mock.chat_scripts[min(n, length(mock.chat_scripts))]
                    mock.chat_request_count[] = n
                    payload = join(script, "\n") * "\n"
                else
                    payload = join(mock.chat_lines, "\n") * "\n"
                end
            end
        else
            lock(mock.script_lock) do
                payload = join(mock.generate_lines, "\n") * "\n"
            end
        end

        write(sock, status_line)
        write(sock, "Content-Type: application/x-ndjson\r\n")
        write(sock, "Content-Length: $(sizeof(payload))\r\n")
        write(sock, "Connection: close\r\n\r\n")
        write(sock, payload)
        flush(sock)
    catch e
        try
            write(
                sock,
                "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            )
        catch
        end
        println(stderr, "OllamaMockServer error: ", sprint(showerror, e))
    finally
        try
            close(sock)
        catch
        end
    end
end

function parse_request_line(line::AbstractString)
    parts = split(strip(line))
    length(parts) >= 2 || return "GET", "/"
    return parts[1], split(parts[2], "?")[1]
end

"""
Read one HTTP request: request line, headers, and (Content-Length delimited) body.
Returns (request_line, headers::Dict, body::String).
"""
function read_http_request(sock)
    headers = Dict{String,String}()
    request_line = ""
    body = ""

    # Read until we have the full header block.
    header_bytes = UInt8[]
    while true
        b = read(sock, UInt8)
        push!(header_bytes, b)
        if length(header_bytes) >= 4 &&
           header_bytes[end-3] == UInt8('\r') &&
           header_bytes[end-2] == UInt8('\n') &&
           header_bytes[end-1] == UInt8('\r') &&
           header_bytes[end] == UInt8('\n')
            break
        end
    end

    header_text = String(header_bytes)
    lines = split(header_text, "\r\n")
    request_line = lines[1]
    for line in lines[2:end]
        idx = findfirst(isequal(':'), line)
        idx === nothing && continue
        name = strip(line[1:idx-1])
        value = strip(line[idx+1:end])
        headers[lowercase(name)] = value
    end

    content_length = parse(Int, get(headers, "content-length", "0"))
    if content_length > 0
        body = String(read(sock, content_length))
    end

    return request_line, headers, body
end

end # module OllamaMockServer
