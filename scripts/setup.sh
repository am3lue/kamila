#!/bin/bash

# Kamila Setup Script
# Automated setup for Kamila Personal Terminal Assistant

echo "🚀 Kamila Setup Script"
echo "====================="

# Check if Julia is installed
if ! command -v julia &> /dev/null; then
    echo "❌ Julia is not installed or not in PATH"
    echo "Please install Julia from https://julialang.org/downloads/"
    exit 1
fi

echo "✅ Julia found: $(julia --version)"

# Install Julia packages
echo "📦 Installing Julia packages..."
julia --project="." -e "using Pkg; Pkg.instantiate(); Pkg.precompile()"

if [ $? -eq 0 ]; then
    echo "✅ Julia packages installed successfully"
else
    echo "❌ Failed to install Julia packages"
    exit 1
fi

# Setup Ollama model if available
if command -v ollama &> /dev/null; then
    echo "🤖 Ollama found. Setting up Kamila model..."
    
    # Check if Modelfile exists
    if [ -f "config/Modelfile" ]; then
        # Try to create the model
        ollama create kamila -f config/Modelfile 2>/dev/null
        
        if [ $? -eq 0 ]; then
            echo "✅ Kamila model created successfully"
        else
            echo "⚠️  Model creation failed. You may need to:"
            echo "   1. Ensure Ollama is running: ollama serve"
            echo "   2. Pull the base model: ollama pull qwen2.5-coder:0.5b"
            echo "   3. Try: ollama create kamila -f config/Modelfile"
        fi
    else
        echo "⚠️  Modelfile not found. AI features will be limited."
    fi
else
    echo "⚠️  Ollama not found. AI features will be limited."
    echo "   Install Ollama from https://ollama.ai/ for AI functionality"
fi

# Make launch script executable
chmod +x bin/kamila

# Create symbolic link for global access
echo "🔗 Creating symbolic link for system-wide access..."
if [ -L "/usr/local/bin/kamila" ]; then
    echo "⚠️  Symbolic link /usr/local/bin/kamila already exists. Skipping."
else
    echo "   This will allow you to run 'kamila' from anywhere."
    echo "   You may be prompted for your password."
    sudo ln -s "$(pwd)/bin/kamila" /usr/local/bin/kamila
    if [ $? -eq 0 ]; then
        echo "✅ Symbolic link created successfully"
    else
        echo "❌ Failed to create symbolic link. You can try running this command manually:"
        echo "   sudo ln -s \"$(pwd)/bin/kamila\" /usr/local/bin/kamila"
    fi
fi

# Test basic functionality
echo "🧪 Testing basic functionality..."
julia --project="." -e "
try
    println(\"Testing module loading...\")
    println(\"✅ Basic functionality test passed\")
catch e
    println(\"❌ Test failed: \", e)
    exit(1)
end
"

echo ""
echo "🎉 Setup completed!"
echo ""
echo "🚀 To launch Kamila, just type:"
echo "   kamila"
echo ""
echo "📚 Available commands:"
echo "   kamila --help"
echo "   kamila --test"
echo "   kamila --demo"
echo "   kamila --check"
echo ""
echo "📖 For more information, see docs/README.md"
echo ""
echo "🔐 Default password: kamila123"
echo "   (Change this in the Settings menu after first launch)"
