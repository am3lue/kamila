"""
test/capability_test.jl — Tests of the 05.3 capability-based permission model.

Covers capability token mint/verify (forged, expired, mismatched, replay),
deny-overrides-token, scope narrowing (batch / sub-agent), `force` as a hint
only, skill `required_capabilities` gating, and the bridge `capability.audit`
route.
"""

using Test
using JSON

using .Kamila
const CAP = Kamila.Capability
const PERM = Kamila.Permission
const AT = Kamila.AgentTools
const ORCH = Kamila.Orchestrator
const BR = Kamila.KamilaBridge
const SK = Kamila.Skills
const MDB = Kamila.MemoryDB

function with_fresh_db(f::Function)
    old_db = get(ENV, "KAMILA_DB", nothing)
    ENV["KAMILA_DB"] = ":memory:"
    try
        MDB.reset!()
        f()
    finally
        MDB.reset!()
        old_db === nothing ? delete!(ENV, "KAMILA_DB") : ENV["KAMILA_DB"] = old_db
    end
end

function with_policy(f::Function, policy::AbstractDict)
    old_file = PERM.POLICY_FILE[]
    policy_path = joinpath(TEST_SANDBOX[]["root"], "cap_policy.json")
    PERM.POLICY_FILE[] = policy_path
    try
        @assert PERM.set_policy(policy) "set_policy failed"
        PERM.clear_session_cache()
        PERM.clear_policy_cache()
        CAP.clear_checks()
        f()
    finally
        PERM.POLICY_FILE[] = old_file
        PERM.clear_session_cache()
        PERM.clear_policy_cache()
        CAP.clear_checks()
    end
end

# A policy that allows everything (used to prove tokens are not even needed).
function allow_all_policy()
    return Dict(
        "version" => 1,
        "rules" => [
            Dict(
                "tool" => "run_shell_command",
                "match" => "*",
                "action" => "allow",
                "scope" => "tool",
            ),
        ],
        "default_action" => "allow",
    )
end

# The starter policy (ask for unknown shell commands, deny dangerous ones).
const STARTER = PERM.starter_policy()

@testset "Capability" begin
    @testset "tool → capability mapping" begin
        @test CAP.tool_capability("run_shell_command") == "shell"
        @test CAP.tool_capability("web_search") == "network"
        @test CAP.tool_capability("write_file") == "files.write"
        @test CAP.tool_capability("read_file") == "files.read"
        @test CAP.tool_capability("memory_query") == "memory.read"
        @test CAP.tool_capability("list_tasks") == "tasks.read"
        @test CAP.tool_capability("unknown_thing") == "core"
    end

    @testset "mint + verify valid token" begin
        args = Dict("command" => "ls -la")
        token = CAP.mint_capability("run_shell_command", args; ttl = 60)
        @test !isempty(token)
        @test CAP.verify_capability("run_shell_command", args, token)
    end

    @testset "forged token rejected" begin
        args = Dict("command" => "ls -la")
        @test !CAP.verify_capability("run_shell_command", args, "forged-token")
        @test !CAP.verify_capability("run_shell_command", args, "")
        # Garbage after valid prefix
        @test !CAP.verify_capability("run_shell_command", args, "abc.def.ghi")
    end

    @testset "mismatched tool / args rejected" begin
        args = Dict("command" => "ls -la")
        token = CAP.mint_capability("run_shell_command", args)
        @test !CAP.verify_capability("web_search", args, token)
        @test !CAP.verify_capability("run_shell_command", Dict("command" => "pwd"), token)
    end

    @testset "expired token rejected" begin
        args = Dict("command" => "ls -la")
        token = CAP.mint_capability("run_shell_command", args; ttl = -30)
        @test !CAP.verify_capability("run_shell_command", args, token)
    end

    @testset "replay protection: token usable once" begin
        args = Dict("command" => "ls -la")
        token = CAP.mint_capability("run_shell_command", args; ttl = 60)
        @test CAP.verify_capability("run_shell_command", args, token)
        @test !CAP.verify_capability("run_shell_command", args, token)
    end

    @testset "scope narrowing: child never gains capabilities" begin
        parent = Set(["shell", "network"])
        # Child declaring only a subset is the intersection.
        @test CAP.restrict_caps(parent, Set(["shell"])) == Set(["shell"])
        # Child declaring something the parent lacks loses it entirely.
        @test CAP.restrict_caps(parent, Set(["shell", "files.write"])) == Set(["shell"])
        # No parent scope: child is capped to what it declares.
        @test CAP.restrict_caps(nothing, Set(["shell"])) == Set(["shell"])
        # Parent without declared needs keeps the parent's set.
        @test CAP.restrict_caps(parent, nothing) == parent
    end

    @testset "in_scope: tool allowed only within its capability" begin
        @test CAP.in_scope("run_shell_command", Set(["shell"]))
        @test !CAP.in_scope("run_shell_command", Set(["files.read"]))
        @test CAP.in_scope("web_search", Set(["network"]))
        @test CAP.in_scope("run_shell_command", nothing)
        @test CAP.in_scope("run_shell_command", Set(["run_shell_command"]))
    end

    @testset "policy grants: default_capabilities + cap: rules" begin
        policy = Dict(
            "version" => 1,
            "rules" => [
                Dict("tool" => "cap:network", "action" => "allow", "scope" => "tool"),
            ],
            "default_action" => "ask",
            "default_capabilities" => ["memory.read", "tasks.read"],
        )
        with_policy(policy) do
            @test PERM.granted_cap("memory.read")
            @test PERM.granted_cap("network")
            @test !PERM.granted_cap("shell")
            @test !PERM.granted_cap("files.write")
        end
    end
end

@testset "Capability integration" begin
    @testset "cap: rule grants whole capability via evaluate" begin
        policy = Dict(
            "version" => 1,
            "rules" => [
                Dict("tool" => "cap:network", "action" => "allow", "scope" => "tool"),
            ],
            "default_action" => "ask",
        )
        with_policy(policy) do
            @test PERM.evaluate("web_search", Dict("query" => "x")) == :allow
            @test PERM.evaluate("run_shell_command", Dict("command" => "echo hi")) == :ask
        end
    end

    @testset "skill: rule targets a named skill" begin
        policy = Dict(
            "version" => 1,
            "rules" => [
                Dict("tool" => "skill:my_grep", "action" => "allow", "scope" => "tool"),
            ],
            "default_action" => "ask",
        )
        with_policy(policy) do
            @test PERM.evaluate("my_grep", Dict("input" => "x")) == :allow
            @test PERM.evaluate("other", Dict()) == :ask
        end
    end

    @testset "default_capabilities allow read-only tools without prompt" begin
        policy = Dict(
            "version" => 1,
            "rules" => [],
            "default_action" => "ask",
            "default_capabilities" => ["files.read", "memory.read"],
        )
        with_policy(policy) do
            @test PERM.evaluate("read_file", Dict("file_path" => "a.txt")) == :allow
            @test PERM.evaluate("memory_query", Dict("query" => "summary")) == :allow
            @test PERM.evaluate("run_shell_command", Dict("command" => "echo hi")) == :ask
        end
    end

    @testset "deny rule overrides any capability token" begin
        with_policy(STARTER) do
            # `rm -rf /` is deny-by-policy; a minted token must not bypass it.
            args = Dict("command" => "rm -rf /")
            token = CAP.mint_capability("run_shell_command", args)
            result = AT.execute_tool_structured(
                "run_shell_command",
                Dict("command" => "rm -rf /", "capability" => token),
            )
            @test !result["ok"]
            @test result["category"] == "permission"
        end
    end

    @testset "force=true without token still follows policy (no bypass)" begin
        with_policy(STARTER) do
            # `echo` is :ask under the starter policy; force alone must not skip.
            result = AT.execute_tool_structured(
                "run_shell_command",
                Dict("command" => "echo force-no-token", "force" => true),
            )
            @test !result["ok"]
            @test result["category"] == "permission"
        end
    end

    @testset "valid token satisfies :ask without prompting" begin
        policy = Dict(
            "version" => 1,
            "rules" => [],
            "default_action" => "ask",
        )
        with_policy(policy) do
            args = Dict("command" => "echo token-approved")
            # `issue_ask_token` only mints when the policy allows; the manual
            # `mint_capability` stands in for an after-approval token.
            token = CAP.mint_capability("run_shell_command", args)
            result = AT.execute_tool_structured(
                "run_shell_command",
                Dict("command" => "echo token-approved", "capability" => token),
            )
            @test result["ok"]
        end
    end

    @testset "batch preflight rejects out-of-scope calls" begin
        with_policy(allow_all_policy()) do
            calls = [
                Dict("tool" => "run_shell_command", "args" => Dict("command" => "ls")),
                Dict("tool" => "web_search", "args" => Dict("query" => "x")),
            ]
            # Scoped to "shell" only: web_search (network) is out of scope.
            @test ORCH.preflight_batch(calls; capabilities = Set(["shell"])) == :permission
            # Scoped to both: passes.
            @test ORCH.preflight_batch(calls; capabilities = Set(["shell", "network"])) ==
                  :allow
        end
    end

    @testset "batch execution enforces scope per call" begin
        with_policy(allow_all_policy()) do
            results = ORCH.execute_batch(
                [
                    Dict("tool" => "run_shell_command", "args" => Dict("command" => "ls")),
                    Dict("tool" => "web_search", "args" => Dict("query" => "x")),
                ];
                capabilities = Set(["shell"]),
            )
            shell = results[findfirst(r -> r["call"] == "run_shell_command", results)]
            web = results[findfirst(r -> r["call"] == "web_search", results)]
            @test shell["ok"]
            @test !web["ok"]
            @test web["category"] == "permission"
        end
    end

    @testset "sub-agent scope: execute_tool_structured narrows capability set" begin
        with_policy(allow_all_policy()) do
            # Parent grants only "network"; a shell call must be denied.
            ok = AT.execute_tool_structured(
                "run_shell_command",
                Dict("command" => "ls");
                capabilities = Set(["network"]),
            )
            @test !ok["ok"]
            @test ok["category"] == "permission"
        end
    end

    @testset "skill required_capabilities gates enable" begin
        with_fresh_db() do
            SK._SEEDED[] = false
            SK.seed_builtins!()
            # A shell skill declares required_capabilities=["shell"]; enable under
            # the starter policy (shell NOT granted) must be refused.
            spec = Dict(
                "name" => "gated_shell_skill",
                "impl_type" => "shell",
                "impl_ref" => "echo {input}",
                "required_capabilities" => ["shell"],
                "parameters" => Dict{String,Any}(),
            )
            with_policy(Dict("version" => 1, "rules" => [], "default_action" => "ask")) do
                @test_throws Exception SK.enable!("gated_shell_skill")
            end
            # Installing directly with enabled=true also refuses.
            spec["description"] = "gated"
            with_policy(Dict("version" => 1, "rules" => [], "default_action" => "ask")) do
                @test_throws Exception SK.install!(spec)
            end
            # Granting "shell" lets the skill be installed and enabled.
            policy = Dict(
                "version" => 1,
                "rules" => [],
                "default_action" => "ask",
                "default_capabilities" => ["shell"],
            )
            with_policy(policy) do
                s = SK.install!(spec)
                @test s !== nothing
                SK.enable!("gated_shell_skill")
                @test SK.get_skill("gated_shell_skill").enabled
            end
        end
    end

    @testset "capability audit records mint + verify" begin
        with_policy(allow_all_policy()) do
            CAP.clear_checks()
            args = Dict("command" => "ls")
            CAP.mint_capability("run_shell_command", args)
            entries = CAP.capability_audit(50)
            @test any(e -> e["event"] == "capability.mint" && e["tool"] == "run_shell_command", entries)
            CAP.clear_checks()
            @test isempty(CAP.capability_audit(50))
        end
    end

    @testset "bridge: capability.audit route" begin
        with_policy(allow_all_policy()) do
            CAP.clear_checks()
            CAP.mint_capability("run_shell_command", Dict("command" => "ls"))
            out = capture_stdout() do
                BR.dispatch(
                    Dict(
                        "type" => "request",
                        "id" => "ca1",
                        "method" => "capability.audit",
                        "params" => Dict("limit" => 5),
                    ),
                )
            end
            events = JSON.parse(strip(out))
            @test events["type"] == "response"
            @test events["id"] == "ca1"
            @test length(events["result"]["checks"]) >= 1
        end
    end

    @testset "bridge: permission.get includes capability info" begin
        old_file = PERM.POLICY_FILE[]
        policy_path = joinpath(TEST_SANDBOX[]["root"], "cap_bridge_policy.json")
        PERM.POLICY_FILE[] = policy_path
        try
            PERM.set_policy(Dict("version" => 1, "rules" => [], "default_action" => "ask"))
            PERM.clear_session_cache()
            out = capture_stdout() do
                BR.dispatch(
                    Dict(
                        "type" => "request",
                        "id" => "pg1",
                        "method" => "permission.get",
                        "params" => Dict(),
                    ),
                )
            end
            events = JSON.parse(strip(out))
            @test events["type"] == "response"
            @test haskey(events["result"], "capabilities")
            @test haskey(events["result"]["capabilities"], "tool_map")
            @test events["result"]["capabilities"]["tool_map"]["run_shell_command"] == "shell"
        finally
            PERM.POLICY_FILE[] = old_file
            PERM.clear_policy_cache()
        end
    end
end