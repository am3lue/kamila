"""
Main Test Suite for Kamila Assistant
Runs all unit and integration tests
"""

using Test

println("🧪 Starting Kamila Test Suite")
println("=" ^ 50)

@testset "Kamila Full Suite" begin
    # 1. Parts of Tools (Unit Tests)
    println("\nRunning Agent Tools unit tests...")
    include("tools_test.jl")
    
    # 2. Agent Logic (Parsing Tests)
    println("\nRunning Agent Logic unit tests...")
    include("agent_logic_test.jl")
end

println("\n" * "=" ^ 50)
println("🎉 All tests completed!")
