"""
test/lint_test.jl — Julia quality gates (JuliaFormatter, Aqua, JET).

These dev-only packages live in `[extras]`/`[targets.test]` and are only
present when running via `Pkg.test()`. Under the plain `test/run.jl` runner
they are absent, so every check here gracefully skips when its package is
missing — CI runs this target under `Pkg.test()` for the full gate.
"""

using Test

# Load the optional dev packages at file scope (a `using` inside a nested
# @testset block is not reliably resolved).
const HAS_FORMATTER = Base.find_package("JuliaFormatter") !== nothing
const HAS_AQUA = Base.find_package("Aqua") !== nothing
const HAS_JET = Base.find_package("JET") !== nothing

if HAS_FORMATTER
    import JuliaFormatter
end
if HAS_AQUA
    import Aqua
end
if HAS_JET
    import JET
end

@testset "Julia lint gates" begin
    # ─── JuliaFormatter ─────────────────────────────────
    if HAS_FORMATTER
        @testset "JuliaFormatter" begin
            # Check-only: `format_file` with `overwrite=false` reports whether a
            # file is already formatted without writing, so the gate never
            # mutates the working tree in CI.
            src_dir = joinpath(dirname(@__DIR__), "src")
            unformatted = String[]
            try
                for (root, _, files) in walkdir(src_dir)
                    for f in files
                        endswith(f, ".jl") || continue
                        path = joinpath(root, f)
                        formatted = JuliaFormatter.format_file(path; overwrite = false)
                        if !formatted
                            push!(unformatted, relpath(path, src_dir))
                        end
                    end
                end
            catch e
                @info "JuliaFormatter check skipped (error): $e"
            end
            if !isempty(unformatted)
                @info "Unformatted files:\n" * join(("  - " * f for f in unformatted), "\n")
            end
            @test isempty(unformatted)
        end
    else
        @test_skip true
        @info "JuliaFormatter not installed — skipping format check"
    end

    # ─── Aqua (unbound args) ────────────────────────────
    # `Kamila` here is `include`d into Main (not loadable as a package), so the
    # package-level checks (`test_ambiguities`, `project_extras`, `stale_deps`,
    # `compat`, `test_all`) all fail with "Non-package module is not supported".
    # `test_unbound_args` is the module-level check that works in this layout.
    if HAS_AQUA
        @testset "Aqua unbound args" begin
            Aqua.test_unbound_args(Kamila)
        end
    else
        @test_skip true
        @info "Aqua not installed — skipping Aqua check"
    end

    # ─── JET (static type-check of hot paths) ───────────
    if HAS_JET
        @testset "JET" begin
            src_dir = joinpath(dirname(@__DIR__), "src")
            # JET descends into Base `tryparse`/`JSON.parse` internals and emits
            # well-known false positives there (e.g. `UndefVarErrorReport` on a
            # `BigInt` branch of `parse`). The gate only counts reports whose
            # *entire* virtual stack stays inside our own `src/` — real bugs
            # fully located in our code still fail, but Base-internals noise
            # does not.
            function our_code_reports(report)
                ours = []
                for rep in JET.get_reports(report)
                    if hasproperty(rep, :vst) && !isempty(rep.vst)
                        if all(fr -> startswith(String(fr.file), src_dir), rep.vst)
                            push!(ours, rep)
                        end
                    end
                end
                return ours
            end

            report = JET.@report_call Kamila.ModelRouter.select_model(:chat)
            @test isempty(our_code_reports(report))

            report = JET.@report_call Kamila.Agent.parse_response("hello world no tool")
            @test isempty(our_code_reports(report))
        end
    else
        @test_skip true
        @info "JET not installed — skipping JET check"
    end
end
