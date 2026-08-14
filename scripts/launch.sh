#!/bin/bash

# Kamila Launch Script v0.2.0

# Default log file under the XDG state dir (override with KAMILA_LOG_FILE).
if [ -z "${KAMILA_LOG_FILE:-}" ]; then
    LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/kamila"
    mkdir -p "$LOG_DIR"
    export KAMILA_LOG_FILE="$LOG_DIR/kamila.log"
fi

echo "Kamila Launch Script"
echo "===================="

if ! command -v julia &> /dev/null; then
    echo "Julia is not installed or not in PATH"
    echo "Install from https://julialang.org/downloads/"
    exit 1
fi

echo "Julia found: $(julia --version)"

if [ ! -f "src/Kamila.jl" ]; then
    echo "Not in the correct Kamila directory"
    exit 1
fi

if [ ! -f "Manifest.toml" ]; then
    echo "Dependencies not found. Running setup..."
    julia --project="." -e "using Pkg; Pkg.instantiate(); Pkg.precompile()"
fi

if command -v ollama &> /dev/null; then
    if curl -s http://localhost:11434/api/tags > /dev/null 2>&1; then
        echo "Ollama server is running"
    else
        echo "Ollama server not detected. AI features may be limited."
    fi
else
    echo "Ollama not found. AI features will be limited."
fi

echo ""
echo "Launching Kamila TUI..."
echo ""

exec "$(dirname "$0")/../bin/kamila" "$@"
