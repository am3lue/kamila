"""
test/runtests.jl — legacy entry point; delegates to the new runner `test/run.jl`.

`include("test/runtests.jl")` runs the full suite exactly like
`julia --project=. test/run.jl`.
"""

include("run.jl")
