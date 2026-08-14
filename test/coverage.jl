"""
test/coverage.jl — parse Julia `.cov` files and print per-module line coverage.

Usage (after running the suite with --code-coverage=user):
    julia test/coverage.jl
    julia test/coverage.jl --min 40

Scans `src/**/*.cov` (and any `.cov` next to source files), counts executable
lines (`n > 0`) vs non-executed (`0`) executable lines, and reports each file's
percentage plus an aggregate per-directory breakdown.
"""

# Collect all .cov files under src/
cov_files = String[]
for (root, dirs, files) in walkdir(joinpath(@__DIR__, "..", "src"))
    for f in files
        endswith(f, ".cov") && push!(cov_files, joinpath(root, f))
    end
end
sort!(cov_files)

function parse_min_arg(args)
    for arg in args
        if startswith(arg, "--min=")
            v = tryparse(Float64, arg[length("--min=")+1:end])
            return v === nothing ? 0.0 : v
        end
    end
    return 0.0
end

min_pct = parse_min_arg(ARGS)

struct FileCov
    path::String
    executable::Int
    executed::Int
end

function analyze_cov(file::String)
    executable = 0
    executed = 0
    for line in eachline(file)
        m = match(r"^\s*(-|\d+)\s+", line)
        m === nothing && continue
        token = m.captures[1]
        token == "-" && continue
        executable += 1
        count = tryparse(Int, token)
        if count !== nothing && count > 0
            executed += 1
        end
    end
    return FileCov(file, executable, executed)
end

results = FileCov[analyze_cov(f) for f in cov_files]

total_executable = sum(r.executable for r in results)
total_executed = sum(r.executed for r in results)

println("📊 Kamila Line Coverage")
println("="^60)
for r in results
    pct = r.executable == 0 ? 100.0 : round(r.executed / r.executable * 100, digits = 1)
    rel = replace(relpath(r.path, joinpath(@__DIR__, "..")), ".cov" => "")
    flag = pct >= min_pct ? "✅" : "❌"
    println("  $flag $rel  ($(r.executed)/$(r.executable) lines, $pct%)")
end

println("="^60)
# Per-directory breakdown
dirs = Dict{String,Tuple{Int,Int}}()
for r in results
    dir = dirname(relpath(r.path, joinpath(@__DIR__, "..")))
    cur = get(dirs, dir, (0, 0))
    dirs[dir] = (cur[1] + r.executed, cur[2] + r.executable)
end
println("Per-directory:")
for dir in sort(collect(keys(dirs)))
    exe, total = dirs[dir]
    pct = total == 0 ? 100.0 : round(exe / total * 100, digits = 1)
    flag = pct >= min_pct ? "✅" : "❌"
    println("  $flag $dir  ($exe/$total lines, $pct%)")
end

println("="^60)
overall =
    total_executable == 0 ? 100.0 :
    round(total_executed / total_executable * 100, digits = 1)
println("Total: $overall%  ($total_executed/$total_executable executable lines)")
println("Minimum required: $min_pct%")

# Exit nonzero if coverage is below the minimum.
if overall < min_pct
    println("❌ Coverage below minimum ($overall% < $min_pct%)")
    exit(1)
else
    println("✅ Coverage meets minimum.")
end
