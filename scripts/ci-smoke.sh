#!/bin/bash
# CI bridge smoke test.
#
# Boots the real Julia bridge against the mocked Ollama server (test/OllamaMockServer.jl)
# and verifies a scripted `ai.status` round trip produces valid JSON-RPC events.
# Used by the GitHub Actions `bridge-smoke` job; runnable locally too.
#
# Exit codes:
#   0 - smoke test passed (or Ollama-dependent checks gracefully skipped)
#   1 - a required check failed
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v julia &> /dev/null; then
    echo "Julia is not installed. Skipping bridge smoke test."
    exit 0
fi

echo "== Bridge smoke test =="

OUT=$(julia --project=. --startup-file=no -e '
using JSON

include("test/helpers.jl")
include("test/OllamaMockServer.jl")
using .OllamaMockServer

# Start the mock BEFORE src/Kamila.jl loads so OLLAMA_HOST binds to it.
mock = OllamaMockServer.start_mock_server()
ENV["OLLAMA_HOST"] = "http://127.0.0.1:$(OllamaMockServer.server_port(mock))"

include("src/Kamila.jl")
using .Kamila
const BR = Kamila.KamilaBridge

function run_bridge_with_input(requests::Vector{String}; read_timeout::Float64=10.0)
    mktemp() do out_path, out_io
        close(out_io)
        open(out_path, "w") do out_h
            mktemp() do path, io
                for r in requests
                    write(io, r * "\n")
                end
                close(io)
                open(path) do stdin_h
                    redirect_stdout(() -> begin
                        redirect_stdin(() -> BR.run_bridge(read_timeout=read_timeout), stdin_h)
                    end, out_h)
                end
            end
        end
        read(out_path, String)
    end
end

output = run_bridge_with_input([
    JSON.json(Dict("type" => "request", "id" => "1", "method" => "ai.status", "params" => Dict()))
])

types = String[]
result_keys = String[]
for line in split(output, "\n")
    isempty(strip(line)) && continue
    ev = try JSON.parse(line) catch; continue end
    push!(types, get(ev, "type", ""))
    if get(ev, "type", "") == "response" && get(ev, "id", "") == "1"
        push!(result_keys, join(sort(collect(keys(get(ev, "result", Dict())))), ","))
    end
end

OllamaMockServer.stop_mock_server(mock)

ready = "ready" in types
got_response = !isempty(result_keys)
ready || error("bridge never emitted ready")
got_response || error("no response to ai.status")
println("PASS bridge smoke: ready=true result_keys=" * result_keys[1])
')

echo "$OUT"
echo "== Bridge smoke passed =="
