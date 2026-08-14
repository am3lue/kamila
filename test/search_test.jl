"""
test/search_test.jl — Fixture-driven tests of the `Search` module (02.4).

Parsing is tested against saved DDG-lite HTML samples (structurally representative,
not byte-for-byte captures): a normal multi-result page, a single-result page with
redirect wrappers + tracking params, an empty page, and a bot/anomaly page. All
network access goes through the `_set_http_get`/`_set_http_post` seam.
"""

using Test
using JSON
using .Kamila

const S = Main.Kamila.Search
const E = Main.Kamila.Errors

# ─── Fixtures ───────────────────────────────────────────────

const FIXTURE_NORMAL = """
<html><body>
<form id="searchform" method="post" action="//lite.duckduckgo.com/lite/">
<input type="hidden" name="q" value="julia lang"/>
</form>
<table class="result">
<tr>
  <td class="result-link">
    <a rel="nofollow" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fjulialang.org">Julia Programming Language</a>
  </td>
  <td class="result-snippet">The official site for the Julia language.</td>
</tr>
<tr>
  <td class="result-link">
    <a rel="nofollow" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fdocs.julialang.org">Julia Documentation</a>
  </td>
  <td class="result-snippet">Reference documentation and manuals.</td>
</tr>
</table>
</body></html>
"""

const FIXTURE_SINGLE_WRAPPED = """
<html><body>
<table class="result">
<tr>
  <td class="result-link">
    <a rel="nofollow" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fblog%3Futm_source%3Dddg%26ref%3Dfoo">Example Blog Post</a>
  </td>
  <td class="result-snippet">A &amp; useful snippet with <b>markup</b> inside.</td>
</tr>
</table>
</body></html>
"""

const FIXTURE_EMPTY = """
<html><body>
<form id="searchform" method="post" action="//lite.duckduckgo.com/lite/">
<input type="hidden" name="q" value="zzzz"/>
</form>
<p>No results found.</p>
</body></html>
"""

const FIXTURE_BOT = """
<html><body>
<h1>Anomaly detected</h1>
<p>We are temporarily unable to serve your request. Please try again later.</p>
<img src="/captcha.png" alt="captcha"/>
</body></html>
"""

# ─── Helpers ────────────────────────────────────────────────

# Canned HTTP responder that counts requests (used for the cache-spy test).
mutable struct CountingHTTP
    body::String
    calls::Vector{String}
end
CountingHTTP(body::String) = CountingHTTP(body, String[])

function install_http!(counting::CountingHTTP)
    S._set_http_get(function (url; headers = Dict(), readtimeout = 15, retry = false)
        push!(counting.calls, url)
        return (body = counting.body, status = 200)
    end)
    return nothing
end

function with_clean_state(f::Function)
    old_get = S._HTTP_GET[]
    old_backend = S._backend_name()
    try
        S.clear_cache()
        S.reset_rate_limit()
        S.configure(TEST_SANDBOX[]["config_file"])
        f()
    finally
        S._set_http_get(old_get)
        S.clear_cache()
        S.reset_rate_limit()
        S._BACKEND[] = old_backend
    end
end

# ─── Tests ──────────────────────────────────────────────────

@testset "Search" begin
    @testset "ddg-lite parsing (fixtures)" begin
        with_clean_state() do
            # Normal page → ≥1 structured result with clean URLs.
            counting = CountingHTTP(FIXTURE_NORMAL)
            install_http!(counting)
            results = S.search("julia lang"; max_results = 5)
            @test results !== nothing
            @test !isempty(results)
            @test results[1][:title] == "Julia Programming Language"
            @test results[1][:url] == "https://julialang.org"
            @test occursin("official site", lowercase(results[1][:snippet]))
            @test results[2][:url] == "https://docs.julialang.org"

            # Redirect wrapper unwrapped; tracking params dropped.
            counting2 = CountingHTTP(FIXTURE_SINGLE_WRAPPED)
            install_http!(counting2)
            single = S.search("example blog"; max_results = 5)
            @test single !== nothing
            @test length(single) == 1
            @test single[1][:title] == "Example Blog Post"
            @test single[1][:url] == "https://example.com/blog"
            @test occursin("A & useful snippet", single[1][:snippet])
        end
    end

    @testset "empty and bot pages → nothing" begin
        with_clean_state() do
            # Empty results page.
            counting = CountingHTTP(FIXTURE_EMPTY)
            install_http!(counting)
            @test S.search("zzzz") === nothing

            # Bot/anomaly page → nothing, never a half-parsed result set.
            counting2 = CountingHTTP(FIXTURE_BOT)
            install_http!(counting2)
            @test S.search("spam query") === nothing
        end
    end

    @testset "rate limiting (token bucket)" begin
        with_clean_state() do
            S.reset_rate_limit()
            # Burst of 5 allowed immediately, then throttled.
            allowed = count(_ -> S._rate_allow(), 1:10)
            @test allowed == 5
            @test S.search("throttled") === nothing
        end
    end

    @testset "cache hit avoids network (spy)" begin
        with_clean_state() do
            counting = CountingHTTP(FIXTURE_NORMAL)
            install_http!(counting)
            first = S.search("cache me"; max_results = 3)
            @test first !== nothing
            @test length(counting.calls) == 1
            second = S.search("cache me"; max_results = 3)
            @test second == first
            @test length(counting.calls) == 1  # cached, no second network call
            # Different max_results → different cache key → new request.
            S.search("cache me"; max_results = 5)
            @test length(counting.calls) == 2
        end
    end

    @testset "failure → nothing, never throws" begin
        with_clean_state() do
            # HTTP seam throws (timeout/network) → Search returns nothing.
            S._set_http_get(
                function (url; headers = Dict(), readtimeout = 15, retry = false)
                    error("timed out")
                end,
            )
            @test S.search("fails") === nothing
        end
    end

    @testset "backend config (custom) switches via config only" begin
        with_clean_state() do
            # Write a config with search.backend=custom + endpoint.
            config_path = TEST_SANDBOX[]["config_file"]
            write(
                config_path,
                JSON.json(
                    Dict(
                        "search" => Dict(
                            "backend" => "custom",
                            "endpoint" => "https://api.example.com/search",
                        ),
                    ),
                ),
            )
            S.configure(config_path)
            @test S._backend_name() == "custom"

            S._set_http_post(
                function (url; headers = Dict(), body = "", readtimeout = 15)
                    return (
                        body = JSON.json(
                            Dict(
                                "results" => [
                                    Dict(
                                        "title" => "T1",
                                        "url" => "https://e.com/1",
                                        "snippet" => "s1",
                                    ),
                                ],
                            ),
                        ),
                        status = 200,
                    )
                end,
            )
            custom = S.search("custom test")
            @test custom !== nothing
            @test custom[1][:title] == "T1"
            @test custom[1][:url] == "https://e.com/1"

            # Reset backend for later tests.
            S._BACKEND[] = "ddg-lite"
        end
    end

    @testset "snippet capped at 300 chars" begin
        with_clean_state() do
            long_snippet = "x"^400
            html = """
            <html><body><table><tr>
              <td class="result-link"><a rel="nofollow" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fex.com">Title</a></td>
              <td class="result-snippet">$long_snippet</td>
            </tr></table></body></html>
            """
            counting = CountingHTTP(html)
            install_http!(counting)
            results = S.search("long")
            @test results !== nothing
            @test length(results[1][:snippet]) <= 303  # 300 + ellipsis char
        end
    end

    @testset "web_search tool delegates to Search (mocked seam)" begin
        with_clean_state() do
            counting = CountingHTTP(FIXTURE_NORMAL)
            install_http!(counting)
            # Uses the same seam the tools test uses; empty query is caught by
            # required-arg validation (:validation) before hitting the backend.
            empty_res = Main.Kamila.AgentTools.execute_tool("web_search", Dict())
            @test occursin("validation", empty_res)
            @test occursin("query", empty_res)
        end
    end

    @testset "network test (opt-in)" begin
        if RUN_NETWORK
            with_clean_state() do
                S._set_http_get(nothing)
                results = S.search("julia lang"; max_results = 3)
                @test results !== nothing
                @test !isempty(results)
            end
        else
            @test_skip "network tests disabled (pass --network)"
        end
    end
end
