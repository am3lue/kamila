#!/bin/bash

# Kamila Launch Script
# Easy launch for Kamila Personal Terminal Assistant

echo "🚀 Kamila Launch Script"
echo "======================="

# Check if Julia is installed
if ! command -v julia &> /dev/null; then
    echo "❌ Julia is not installed or not in PATH"
    echo "Please install Julia from https://julialang.org/downloads/"
    exit 1
fi

echo "✅ Julia found: $(julia --version)"

# Check if we're in the correct directory
if [ ! -f "src/Kamila.jl" ]; then
    echo "❌ Not in the correct Kamila directory"
    echo "Please run this script from the Kamila root directory"
    exit 1
fi

# Check if dependencies are installed
if [ ! -d ".julia" ] && [ ! -f "Manifest.toml" ]; then
    echo "📦 Dependencies not found. Running setup..."
    if [ -f "scripts/setup.sh" ]; then
        ./scripts/setup.sh
    else
        echo "Installing Julia packages..."
        julia --project="." -e "using Pkg; Pkg.instantiate(); Pkg.precompile()"
    fi
fi

# Check Ollama availability
if command -v ollama &> /dev/null; then
    echo "🤖 Ollama found: $(ollama --version)"
    
    # Check if Ollama is running
    if curl -s http://localhost:11434/api/tags > /dev/null 2>&1; then
        echo "✅ Ollama server is running"
    else
        echo "⚠️  Ollama server not detected. AI features may be limited."
        echo "   Start with: ollama serve"
    fi
else
    echo "⚠️  Ollama not found. AI features will be limited."
    echo "   Install from: https://ollama.ai/"
fi

echo ""
echo "🎯 Launching Kamila..."
echo ""

# Launch Kamila
julia --project="." src/Kamila.jl "$@"
exit
