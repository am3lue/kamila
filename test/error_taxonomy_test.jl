"""
test/error_taxonomy_test.jl — Tests for the `Errors` module (typed error taxonomy).

Covers the category table, HTTP status mapping, retryability flags, the
structured payload, string rendering, bridge error events, tool error
categorization, and `ModelRouter`'s structured-error detection.
"""

using Test
using JSON

using .Kamila

const E = Kamila.Errors
const MR = Kamila.ModelRouter
const PERM_ = Kamila.Permission

# Allow write_file without prompting (the new policy gates it with :ask).
function with_permissive_write(f::Function)
    old_file = PERM_.POLICY_FILE[]
    PERM_.POLICY_FILE[] = joinpath(TEST_SANDBOX[]["root"], "err_perm.json")
    try
        @assert PERM_.set_policy(
            Dict(
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
            ),
        )
        PERM_.clear_session_cache()
        PERM_.clear_policy_cache()
        f()
    finally
        PERM_.POLICY_FILE[] = old_file
        PERM_.clear_session_cache()
        PERM_.clear_policy_cache()
    end
end

@testset "Errors" begin
    @testset "category table" begin
        expected = [
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
        @test E.CATEGORIES == expected
        @test length(unique(E.CATEGORIES)) == length(E.CATEGORIES)
    end

    @testset "http_status mapping" begin
        @test E.http_status(:permission) == 403
        @test E.http_status(:validation) == 400
        @test E.http_status(:notfound) == 404
        @test E.http_status(:timeout) == 504
        @test E.http_status(:network) == 503
        @test E.http_status(:external) == 502
        @test E.http_status(:model) == 502
        @test E.http_status(:internal) == 500
        @test E.http_status(:unsupported) == 501
    end

    @testset "retryability" begin
        for cat in [:timeout, :network, :external, :model]
            @test E.is_retryable(E.KamilaError(cat, "x"))
        end
        for cat in [:permission, :validation, :notfound, :internal, :unsupported]
            @test !E.is_retryable(E.KamilaError(cat, "x"))
        end
    end

    @testset "constructor defaults" begin
        err = E.KamilaError(:permission, "nope")
        @test err.category == :permission
        @test err.code == 403
        @test !err.retryable
        @test err.details == Dict{String,Any}()

        terr = E.KamilaError(:timeout, "slow", details = Dict("path" => "/x"))
        @test terr.code == 504
        @test terr.retryable
        @test terr.details == Dict("path" => "/x")

        # explicit overrides: retryable can be forced on for a non-retryable
        # category, but cannot be forced off for a retryable one (a network
        # error is always safe to retry).
        e2 = E.KamilaError(:network, "x", code = 999)
        @test e2.code == 999
        @test e2.retryable

        e3 = E.KamilaError(:validation, "x", retryable = true)
        @test e3.retryable
    end

    @testset "error_category" begin
        @test E.error_category(E.KamilaError(:notfound, "missing")) == :notfound
        @test E.error_category(ErrorException("boom")) == :internal
    end

    @testset "error_string" begin
        err = E.KamilaError(:validation, "bad input")
        s = E.error_string(err)
        @test s == "Error [validation] bad input"

        err2 = E.KamilaError(:network, "refused", details = Dict("host" => "x"))
        s2 = E.error_string(err2)
        @test startswith(s2, "Error [network] refused ")
        @test occursin("\"host\"", s2)

        @test occursin("boom", E.error_string(ErrorException("boom")))
    end

    @testset "error_payload" begin
        err = E.KamilaError(:model, "bad model", details = Dict("model" => "m"))
        p = E.error_payload(err)
        @test p["ok"] == false
        @test p["category"] == "model"
        @test p["message"] == "bad model"
        @test p["code"] == 502
        @test p["retryable"] == true
        @test p["details"] == Dict("model" => "m")

        # JSON round-trips (bridge serializes this).
        j = JSON.json(p)
        back = JSON.parse(j)
        @test back["category"] == "model"
        @test back["retryable"] == true
        @test back["code"] == 502

        # Generic exception degrades gracefully.
        p2 = E.error_payload(ErrorException("boom"))
        @test p2["ok"] == false
        @test p2["category"] == "internal"
        @test p2["code"] == 500
    end

    @testset "showerror" begin
        err = E.KamilaError(:permission, "denied")
        io = IOBuffer()
        showerror(io, err)
        @test String(take!(io)) == "permission error: denied"
    end

    @testset "ModelRouter structured error detection" begin
        @test MR.is_error_response("Error [timeout] request hung")
        @test MR.is_error_response("Error [network] connection refused")
        @test MR.is_error_response("Error [permission] denied")
        @test MR.is_error_response("Error [bogus] x")  # unknown cat degrades to :internal
        @test !MR.is_error_response("Everything is fine")
        @test MR.is_error_response("")  # empty responses are treated as failures

        @test MR.error_category_of("Error [timeout] x") == :timeout
        @test MR.error_category_of("Error [permission] x") == :permission
        @test MR.error_category_of("Error [bogus] x") == :internal
        @test MR.error_category_of("timeout: whatever") == :network
        @test MR.error_category_of("ok") === nothing
        @test MR.error_category_of("") == :internal
    end

    @testset "tool error categorization" begin
        AT = Kamila.AgentTools
        allowed = TEST_SANDBOX[]["allowed"]
        with_permissive_write() do

            # Validation error: missing required arg.
            r = AT.execute_tool_structured("read_file", Dict())
            @test r["ok"] == false
            @test r["category"] == "validation"
            @test r["retryable"] == false
            @test occursin("Error [validation]", r["result"])

            # Permission error: path outside allowed dirs.
            rp = AT.execute_tool_structured("read_file", Dict("file_path" => "/etc/passwd"))
            @test rp["ok"] == false
            @test rp["category"] == "permission"
            @test rp["retryable"] == false
            @test occursin("Error [permission]", rp["result"])

            # Not-found error: nonexistent file inside the allowed dir.
            rn = AT.execute_tool_structured(
                "read_file",
                Dict("file_path" => joinpath(allowed, "nope.txt")),
            )
            @test rn["ok"] == false
            @test rn["category"] == "notfound"
            @test rn["retryable"] == false

            # Unknown tool → notfound.
            rt = AT.execute_tool_structured("no_such_tool", Dict())
            @test rt["ok"] == false
            @test rt["category"] == "notfound"

            # Success path.
            f = joinpath(allowed, "taxonomy_test.txt")
            ok = AT.execute_tool_structured(
                "write_file",
                Dict("file_path" => f, "content" => "hi"),
            )
            @test ok["ok"] == true
            @test ok["category"] == "success"
            @test ok["code"] == 0

            # String wrapper still works (compat shim).
            @test occursin("Error executing tool", AT.execute_tool("read_file", Dict()))
        end
    end
end
