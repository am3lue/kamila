"""
test/permission_test.jl — Tests of the `Permission` policy engine (02.2).

Covers rule ordering/matching, default_action, the session cache, HMAC
capability tokens (including forged-token rejection), the audit trail, and the
bridge `permission.*` routes.
"""

using Test
using JSON

using .Kamila
const PERM = Kamila.Permission
const BR = Kamila.KamilaBridge

# Install a fresh policy for each test and restore afterwards.
function with_policy(f::Function, policy::AbstractDict)
    old_file = PERM.POLICY_FILE[]
    policy_path = joinpath(TEST_SANDBOX[]["root"], "perm_policy.json")
    PERM.POLICY_FILE[] = policy_path
    try
        @assert PERM.set_policy(policy) "set_policy failed"
        PERM.clear_session_cache()
        PERM.clear_policy_cache()
        f()
    finally
        PERM.POLICY_FILE[] = old_file
        PERM.clear_session_cache()
        PERM.clear_policy_cache()
    end
end

const STARTER = PERM.starter_policy()

@testset "Permission" begin
    @testset "starter policy: dangerous commands denied" begin
        with_policy(STARTER) do
            @test PERM.evaluate("run_shell_command", Dict("command" => "rm -rf /")) == :deny
            @test PERM.evaluate(
                "run_shell_command",
                Dict("command" => "sudo apt install x"),
            ) == :deny
            @test PERM.evaluate("run_shell_command", Dict("command" => "reboot")) == :deny
            @test PERM.evaluate(
                "run_shell_command",
                Dict("command" => "mkfs.ext4 /dev/sdb"),
            ) == :deny
        end
    end

    @testset "starter policy: safe commands allowed" begin
        with_policy(STARTER) do
            @test PERM.evaluate("run_shell_command", Dict("command" => "ls -la")) == :allow
            @test PERM.evaluate("run_shell_command", Dict("command" => "cat file.txt")) ==
                  :allow
            @test PERM.evaluate("run_shell_command", Dict("command" => "pwd")) == :allow
        end
    end

    @testset "unknown command -> ask (default_action)" begin
        with_policy(STARTER) do
            @test PERM.evaluate("run_shell_command", Dict("command" => "echo hello")) ==
                  :ask
            # "rm" must not match inside the word "confirm".
            @test PERM.evaluate(
                "run_shell_command",
                Dict("command" => "echo confirm-roundtrip-ok"),
            ) == :ask
        end
    end

    @testset "evaluate returns the rule that fired" begin
        with_policy(STARTER) do
            @test PERM._evaluate_with_rule("run_shell_command", Dict("command" => "ls")) ==
                  (:allow, "ls|cat|pwd")
            @test PERM._evaluate_with_rule(
                "run_shell_command",
                Dict("command" => "rm -rf /"),
            ) == (:deny, "rm|mv|shutdown|reboot|mkfs|sudo")
            @test PERM._evaluate_with_rule(
                "run_shell_command",
                Dict("command" => "echo hi"),
            ) == (:ask, "default")
        end
    end

    @testset "first matching rule wins (rule order)" begin
        policy = Dict(
            "version" => 1,
            "rules" => [
                Dict(
                    "tool" => "run_shell_command",
                    "match" => "git",
                    "action" => "deny",
                    "scope" => "pattern",
                ),
                Dict(
                    "tool" => "run_shell_command",
                    "match" => "git status",
                    "action" => "allow",
                    "scope" => "pattern",
                ),
            ],
            "default_action" => "ask",
        )
        with_policy(policy) do
            # First rule (deny git) wins even though a later rule would allow.
            @test PERM.evaluate("run_shell_command", Dict("command" => "git status")) ==
                  :deny
        end
    end

    @testset "tool-scope rule applies regardless of args" begin
        policy = Dict(
            "version" => 1,
            "rules" => [
                Dict(
                    "tool" => "write_file",
                    "match" => "*",
                    "action" => "allow",
                    "scope" => "tool",
                ),
            ],
            "default_action" => "ask",
        )
        with_policy(policy) do
            @test PERM.evaluate("write_file", Dict("file_path" => "/any/where.txt")) ==
                  :allow
        end
    end

    @testset "default deny blocks everything not matched" begin
        policy = Dict("version" => 1, "rules" => [], "default_action" => "deny")
        with_policy(policy) do
            @test PERM.evaluate("run_shell_command", Dict("command" => "echo hi")) == :deny
            @test PERM.evaluate("read_file", Dict("file_path" => "a.txt")) == :deny
        end
    end

    @testset "session cache remembers decisions" begin
        policy = Dict(
            "version" => 1,
            "rules" => [
                Dict(
                    "tool" => "run_shell_command",
                    "match" => "echo",
                    "action" => "ask",
                    "scope" => "pattern",
                ),
            ],
            "default_action" => "ask",
            "session_remember" => true,
        )
        with_policy(policy) do
            args = Dict("command" => "echo same-command")
            @test PERM.evaluate("run_shell_command", args) == :ask
            # User approves once.
            PERM.remember_decision("run_shell_command", args, :allow)
            @test PERM.evaluate("run_shell_command", args) == :allow
            # A different command is NOT cached.
            @test PERM.evaluate("run_shell_command", Dict("command" => "echo other")) ==
                  :ask
        end
    end

    @testset "session cache respects session_remember=false" begin
        policy = Dict(
            "version" => 1,
            "rules" => [
                Dict(
                    "tool" => "run_shell_command",
                    "match" => "echo",
                    "action" => "ask",
                    "scope" => "pattern",
                ),
            ],
            "default_action" => "ask",
            "session_remember" => false,
        )
        with_policy(policy) do
            args = Dict("command" => "echo again")
            PERM.remember_decision("run_shell_command", args, :allow)
            @test PERM.evaluate("run_shell_command", args) == :ask
        end
    end

    @testset "capability tokens: issue + verify" begin
        policy = Dict(
            "version" => 1,
            "rules" => [
                Dict(
                    "tool" => "run_shell_command",
                    "match" => "echo",
                    "action" => "allow",
                    "scope" => "pattern",
                ),
            ],
            "default_action" => "ask",
        )
        with_policy(policy) do
            args = Dict("command" => "echo token-test")
            token = PERM.issue_capability("run_shell_command", args)
            @test !isempty(token)
            @test PERM.verify_capability("run_shell_command", args, token)
        end
    end

    @testset "capability tokens: not issued on ask/deny" begin
        with_policy(STARTER) do
            # `echo` is :ask under the starter policy -> no token.
            @test isempty(
                PERM.issue_capability("run_shell_command", Dict("command" => "echo nope")),
            )
            # `rm` is :deny -> no token.
            @test isempty(
                PERM.issue_capability("run_shell_command", Dict("command" => "rm x")),
            )
        end
    end

    @testset "capability tokens: forged token rejected" begin
        with_policy(STARTER) do
            args = Dict("command" => "ls")
            @test !PERM.verify_capability("run_shell_command", args, "forged-token")
            @test !PERM.verify_capability("run_shell_command", args, "")
            # Token for a different command does not verify.
            other = PERM.issue_capability("run_shell_command", Dict("command" => "pwd"))
            @test !PERM.verify_capability("run_shell_command", args, other)
        end
    end

    @testset "capability tokens: token for one session invalid after secret reset" begin
        with_policy(STARTER) do
            args = Dict("command" => "ls")
            token = PERM.issue_capability("run_shell_command", args)
            # Simulate a fresh process: a different, known session secret.
            # (`rand` is not used: Julia's @testset re-seeds the RNG, so it would
            # hand back the same bytes as module load.)
            PERM._SESSION_SECRET[] = zeros(UInt8, 32)
            @test !PERM.verify_capability("run_shell_command", args, token)
        end
    end

    @testset "audit trail records decisions" begin
        with_policy(STARTER) do
            # Reset audit for a clean assertion.
            empty!(PERM._AUDIT)
            PERM.evaluate("run_shell_command", Dict("command" => "ls"))
            PERM.evaluate("run_shell_command", Dict("command" => "rm -rf /"))
            entries = PERM.recent_decisions(10)
            actions = [e["action"] for e in entries]
            @test "allow" in actions
            @test "deny" in actions
            @test all(e -> haskey(e, "tool") && haskey(e, "ts"), entries)
            @test all(e -> e["tool"] == "run_shell_command", entries)
        end
    end

    @testset "audit ring capped at 50" begin
        with_policy(STARTER) do
            empty!(PERM._AUDIT)
            for i = 1:70
                PERM.evaluate("run_shell_command", Dict("command" => "ls $i"))
            end
            @test length(PERM.recent_decisions(200)) == 50
            # recent_decisions(10) returns only 10
            @test length(PERM.recent_decisions(10)) == 10
        end
    end

    @testset "policy file persistence" begin
        policy = Dict("version" => 1, "rules" => [], "default_action" => "deny")
        with_policy(policy) do
            @test isfile(PERM.POLICY_FILE[])
            loaded = JSON.parsefile(PERM.POLICY_FILE[])
            @test loaded["default_action"] == "deny"
        end
    end

    @testset "starter policy written when file missing (ensure_policy_file)" begin
        old_file = PERM.POLICY_FILE[]
        missing = joinpath(mktempdir(), "missing_policy.json")
        PERM.POLICY_FILE[] = missing
        try
            PERM.ensure_policy_file()
            @test isfile(missing)
            loaded = JSON.parsefile(missing)
            @test haskey(loaded, "rules")
            @test loaded["default_action"] == "ask"
        finally
            PERM.POLICY_FILE[] = old_file
            PERM.clear_policy_cache()
        end
    end

    @testset "bridge: permission.get / set / decisions routes" begin
        old_file = PERM.POLICY_FILE[]
        policy_path = joinpath(TEST_SANDBOX[]["root"], "bridge_policy.json")
        PERM.POLICY_FILE[] = policy_path
        try
            PERM.set_policy(Dict("version" => 1, "rules" => [], "default_action" => "ask"))
            PERM.clear_session_cache()

            out = capture_stdout() do
                BR.dispatch(
                    Dict(
                        "type" => "request",
                        "id" => "p1",
                        "method" => "permission.get",
                        "params" => Dict(),
                    ),
                )
            end
            events = JSON.parse(strip(out))
            @test events["type"] == "response"
            @test events["id"] == "p1"
            @test events["result"]["policy"]["default_action"] == "ask"

            # permission.set with a valid policy
            out = capture_stdout() do
                BR.dispatch(
                    Dict(
                        "type" => "request",
                        "id" => "p2",
                        "method" => "permission.set",
                        "params" => Dict(
                            "policy" => Dict(
                                "version" => 1,
                                "rules" => [],
                                "default_action" => "deny",
                            ),
                        ),
                    ),
                )
            end
            events = JSON.parse(strip(out))
            @test events["result"]["success"] == true
            @test events["result"]["policy"]["default_action"] == "deny"

            # permission.set with an invalid policy -> 400
            out = capture_stdout() do
                BR.dispatch(
                    Dict(
                        "type" => "request",
                        "id" => "p3",
                        "method" => "permission.set",
                        "params" => Dict("policy" => Dict("rules" => [])),
                    ),
                )
            end
            events = JSON.parse(strip(out))
            @test events["type"] == "error"
            @test events["code"] == 400

            # decisions route
            empty!(PERM._AUDIT)
            PERM.evaluate("run_shell_command", Dict("command" => "ls"))
            out = capture_stdout() do
                BR.dispatch(
                    Dict(
                        "type" => "request",
                        "id" => "p4",
                        "method" => "permission.decisions",
                        "params" => Dict("limit" => 5),
                    ),
                )
            end
            events = JSON.parse(strip(out))
            @test events["type"] == "response"
            @test length(events["result"]["decisions"]) >= 1
        finally
            PERM.POLICY_FILE[] = old_file
            PERM.clear_policy_cache()
            PERM.clear_session_cache()
        end
    end

    @testset "bridge: permission.reset restores starter" begin
        old_file = PERM.POLICY_FILE[]
        policy_path = joinpath(TEST_SANDBOX[]["root"], "bridge_policy2.json")
        PERM.POLICY_FILE[] = policy_path
        try
            PERM.set_policy(
                Dict("version" => 1, "rules" => [], "default_action" => "allow"),
            )
            out = capture_stdout() do
                BR.dispatch(
                    Dict(
                        "type" => "request",
                        "id" => "p5",
                        "method" => "permission.reset",
                        "params" => Dict(),
                    ),
                )
            end
            events = JSON.parse(strip(out))
            @test events["result"]["success"] == true
            @test events["result"]["policy"]["default_action"] == "ask"
        finally
            PERM.POLICY_FILE[] = old_file
            PERM.clear_policy_cache()
        end
    end
end
