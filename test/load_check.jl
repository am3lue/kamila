
push!(LOAD_PATH, joinpath(@__DIR__, "../src"))
include("../src/Kamila.jl")

using .Kamila
using .Kamila.MaskMode
using Test

println("✅ Kamila module loaded successfully.")
println("✅ MaskMode module loaded successfully.")

# Check if MaskMode has the secret constants (indirectly)
# We can't access private constants easily, but successful load is the main test here.
