"""
test/run.jl — Kamila test runner.

Usage:
    julia --project=. test/run.jl                    # run everything
    julia --project=. test/run.jl --target tools     # run one target
    julia --project=. test/run.jl tools agent        # run several targets
    julia --project=. test/run.jl --ci               # strict mode (fail fast)
    julia --project=. test/run.jl --coverage         # also emit .cov files
    julia --project=. test/run.jl --network          # include network-backed tests

Targets map to files:
    tools      -> test/tools_test.jl
    agent      -> test/agent_test.jl
    agentstream-> test/agent_stream_test.jl
    memory     -> test/memory_test.jl
    tasks      -> test/task_manager_test.jl
    security   -> test/security_test.jl
    bridge     -> test/bridge_test.jl
    confirm    -> test/confirm_test.jl
    permission -> test/permission_test.jl
    monitor    -> test/monitor_test.jl
    search     -> test/search_test.jl
    modelrouter-> test/model_router_test.jl
    log        -> test/log_test.jl
    error      -> test/error_taxonomy_test.jl
    lint       -> test/lint_test.jl
"""

using Test

const TARGETS = Dict(
    "tools" => "tools_test.jl",
    "agent" => "agent_test.jl",
    "agentstream" => "agent_stream_test.jl",
    "memory" => "memory_test.jl",
    "tasks" => "task_manager_test.jl",
    "security" => "security_test.jl",
    "bridge" => "bridge_test.jl",
    "confirm" => "confirm_test.jl",
    "permission" => "permission_test.jl",
    "monitor" => "monitor_test.jl",
    "search" => "search_test.jl",
    "modelrouter" => "model_router_test.jl",
    "log" => "log_test.jl",
    "error" => "error_taxonomy_test.jl",
    "lint" => "lint_test.jl",
    "memorydb" => "memory_db_test.jl",
    "vectors" => "vectors_test.jl",
    "episodic" => "episodic_test.jl",
    "context" => "context_test.jl",
)

function parse_args()
    targets = String[]
    ci = false
    coverage = false
    network = false
    args = copy(ARGS)
    i = 1
    while i <= length(args)
        arg = args[i]
        if arg == "--ci"
            ci = true
        elseif arg == "--coverage"
            coverage = true
        elseif arg == "--network"
            network = true
        elseif arg == "--target"
            i += 1
            if i > length(args)
                println(stderr, "--target requires a value")
                exit(2)
            end
            push!(targets, args[i])
        elseif startswith(arg, "--target=")
            push!(targets, arg[(length("--target=")+1):end])
        elseif startswith(arg, "-")
            println(stderr, "Unknown option: $arg")
            exit(2)
        else
            push!(targets, arg)
        end
        i += 1
    end
    if isempty(targets)
        targets = sort(collect(keys(TARGETS)))
        # lint needs [extras] deps only present under Pkg.test(); skip by default.
        filter!(!=("lint"), targets)
    end
    return targets, ci, coverage, network
end

targets, ci, coverage, network = parse_args()

for t in targets
    if !haskey(TARGETS, t)
        println(
            stderr,
            "Unknown target: $t (valid: $(join(sort(collect(keys(TARGETS))), ", ")))",
        )
        exit(2)
    end
end

# Test-global flags (referenced by test files).
const RUN_CI = ci
const RUN_NETWORK = network

# Sandbox info, populated by `with_sandbox` below; test files read this.
const TEST_SANDBOX = Ref{Any}(nothing)

include("helpers.jl")

# Mock Ollama server used by the bridge/agent round-trip target. Loaded at the
# top level so its functions exist in an earlier world age than the test scope.
include("OllamaMockServer.jl")

println("🧪 Kamila test runner")
println("  targets:  $(join(targets, ", "))")
println("  ci:       $ci")
println("  coverage: $coverage")
println("  network:  $network")
println("="^50)

# The real production module is loaded once, inside a sandbox, so Tier-1 tests
# run against the actual src/ code with isolated filesystem state.
with_sandbox() do info
    TEST_SANDBOX[] = info

    # Bridge/agent round-trip tests need a reachable Ollama. Start the mock
    # server BEFORE loading src/Kamila.jl because OLLAMA_HOST is read as a
    # `const` at module load time.
    mock = nothing
    old_ollama_host = get(ENV, "OLLAMA_HOST", nothing)
    if "bridge" in targets || "modelrouter" in targets
        mock = OllamaMockServer.start_mock_server()
        ENV["OLLAMA_HOST"] = "http://127.0.0.1:$(OllamaMockServer.server_port(mock))"
        TEST_SANDBOX[]["mock_server"] = mock
    end

    try
        include(joinpath(dirname(@__DIR__), "src", "Kamila.jl"))
        # `Kamila` module is now defined in Main.

        @testset "Kamila Test Suite" begin
            for t in targets
                println("\n── Target: $t ──")
                include(joinpath(@__DIR__, TARGETS[t]))
            end
        end
    finally
        if mock !== nothing
            OllamaMockServer.stop_mock_server(mock)
        end
        old_ollama_host === nothing ? delete!(ENV, "OLLAMA_HOST") :
        ENV["OLLAMA_HOST"] = old_ollama_host
    end
end
