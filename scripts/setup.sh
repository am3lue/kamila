#!/bin/bash

# Kamila Setup Script v0.2.0

echo "Kamila Setup Script"
echo "==================="

if ! command -v julia &> /dev/null; then
    echo "Julia is not installed or not in PATH"
    echo "Install from https://julialang.org/downloads/"
    exit 1
fi

echo "Julia found: $(julia --version)"

echo "Installing Julia packages..."
julia --project="." -e "using Pkg; Pkg.instantiate(); Pkg.precompile()"
if [ $? -eq 0 ]; then
    echo "Julia packages installed"
else
    echo "Failed to install Julia packages"
    exit 1
fi

if command -v node &> /dev/null; then
    echo "Installing TUI dependencies..."
    (cd tui && npm install)
    if [ -d "tui-v2" ]; then
        echo "Installing TUI v2 dependencies..."
        (cd tui-v2 && npm install)
    fi
else
    echo "Node.js not found. TUI will not work."
    echo "Install from https://nodejs.org/"
fi

if command -v ollama &> /dev/null; then
    echo "Setting up Ollama models..."
    if [ -f "config/Modelfile.online" ]; then
        ollama create kamila1 -f config/Modelfile.online 2>/dev/null
        if [ $? -eq 0 ]; then
            echo "kamila1 (online) created"
        else
            echo "kamila1 creation failed. Ensure Ollama is running: ollama serve"
        fi
    fi
    if [ -f "config/Modelfile.offline" ]; then
        ollama create kamila2 -f config/Modelfile.offline 2>/dev/null
        if [ $? -eq 0 ]; then
            echo "kamila2 (offline) created"
        else
            echo "kamila2 creation failed. Ensure Ollama is running: ollama serve"
        fi
    fi
else
    echo "Ollama not found. AI features limited."
fi

chmod +x bin/kamila

echo "Checking desktop-context dependencies..."
echo "  - Desktop context reads the active window + clipboard (Wayland/X11)."
echo "  - X11: xsel recommended. Wayland: depends on your compositor."
echo "  - KDE Plasma: qdbus6/qdbus + klipper (clipboard); kdotool recommended for active window (falls back to KWin scripting via qdbus + journalctl)."
echo "  - Sway: swaymsg + wl-paste + jq."
if command -v xsel &> /dev/null; then echo "  [ok] xsel"; else echo "  [warn] xsel not found (X11 clipboard)"; fi
if command -v qdbus6 &> /dev/null || command -v qdbus &> /dev/null; then echo "  [ok] qdbus (KDE D-Bus)"; else echo "  [warn] qdbus not found (KDE desktop context)"; fi
if command -v kdotool &> /dev/null; then echo "  [ok] kdotool (KDE active window)"; else echo "  [warn] kdotool not found (falls back to KWin scripting)"; fi

echo "Verifying platform restriction..."
echo "  - Set KAMILA_ARCH_RESTRICT=strict to hard-require Arch Linux (exit if not), warn to print a warning, or off (default) to allow any distro."

echo "Creating system-wide symlink..."
if [ -L "/usr/local/bin/kamila" ]; then
    echo "Symlink already exists"
else
    sudo ln -s "$(pwd)/bin/kamila" /usr/local/bin/kamila 2>/dev/null && echo "Symlink created" || echo "Could not create symlink (run manually: sudo ln -s \"$(pwd)/bin/kamila\" /usr/local/bin/kamila)"
fi

echo ""
echo "Setup complete!"
echo "Launch: kamila"
