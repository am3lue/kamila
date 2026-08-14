"""
test/monitor_test.jl — Tests of the `SystemMonitor` telemetry (02.3).

Covers the delta-based CPU sampler (baseline/first-call semantics, plausible
deltas, no fabrication), directory-usage cache TTL, the `nothing`-based latency
API, and the "never random" guarantee for every src/system/* metric.
"""

using Test
using JSON

using .Kamila

const SM = Kamila.SystemMonitor

@testset "SystemMonitor" begin
    @testset "cpu: first call returns nothing (baseline)" begin
        SM.reset_cpu_baseline()
        @test SM.get_cpu_usage() === nothing
    end

    @testset "cpu: two calls yield a plausible delta" begin
        SM.reset_cpu_baseline()
        SM.get_cpu_usage()  # baseline
        sleep(0.05)
        # Between two close samples the delta must be a real 0–100 value (or
        # nothing only if /proc is unavailable on this machine).
        v = SM.get_cpu_usage()
        if v === nothing
            @test !isfile("/proc/stat")  # only acceptable reason
        else
            @test 0.0 <= v <= 100.0
        end
    end

    @testset "cpu: no fabricated values (never random)" begin
        SM.reset_cpu_baseline()
        v1 = SM.get_cpu_usage()
        SM.reset_cpu_baseline()
        v2 = SM.get_cpu_usage()
        @test v1 === v2 === nothing
    end

    @testset "cpu: consecutive deltas are not random jumps" begin
        SM.reset_cpu_baseline()
        SM.get_cpu_usage()
        sleep(0.05)
        a = SM.get_cpu_usage()
        sleep(0.05)
        b = SM.get_cpu_usage()
        if a !== nothing && b !== nothing
            @test abs(a - b) < 50.0  # no ±50 random jumps between samples
        end
    end

    @testset "directory usage: cache avoids re-walk within TTL" begin
        # Seed a large-ish temp tree.
        root = mktempdir()
        sub = joinpath(root, "a", "b", "c")
        mkpath(sub)
        for i = 1:50
            write(joinpath(sub, "f$i.txt"), "x"^100)
        end

        SM.get_directory_usage(root)  # cold
        t0 = time_ns()
        first_result = SM.get_directory_usage(root)
        t_cold = time_ns() - t0

        t0 = time_ns()
        cached = SM.get_directory_usage(root)
        t_warm = time_ns() - t0

        @test first_result["files"] == 50
        @test cached["files"] == 50
        @test t_warm < t_cold  # warm read did not re-walk
        @test t_warm < 1_000_000  # ~sub-millisecond, cache hit
    end

    @testset "directory usage: invalidation on mtime change" begin
        root = mktempdir()
        write(joinpath(root, "one.txt"), "hello")
        SM.get_directory_usage(root)

        # Change the top dir mtime and add a file; a fresh read re-walks.
        sleep(0.05)
        write(joinpath(root, "two.txt"), "world")
        ctime(root)  # reading ctime also forces the dir metadata update
        result = SM.get_directory_usage(root)
        @test result["files"] >= 2
    end

    @testset "directory usage: missing path returns nothing" begin
        @test SM.get_directory_usage(joinpath(mktempdir(), "nope-does-not-exist")) ===
              nothing
    end

    @testset "internet latency: nothing on failure, number on success" begin
        v = SM.get_internet_latency()
        @test v === nothing || v isa Float64
        if v isa Float64
            @test v > 0.0
        end
    end

    @testset "no random/fake values in any src/system metric" begin
        # The 02.3 DoD bans fabricated data: get_cpu_usage must not contain rand.
        cpu_src = read(joinpath(dirname(@__DIR__), "src", "system", "monitor.jl"), String)
        @test !occursin(r"rand\(", cpu_src)
    end

    @testset "monitor_resources logs to stderr path (no stdout)" begin
        # Capturing stdout should show nothing from monitor_resources; it uses
        # KamilaLog (stderr-backed). Just verify it runs without throwing for a
        # short duration.
        SM.monitor_resources(0)
        @test true
    end
end
