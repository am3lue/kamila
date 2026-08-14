#!/bin/bash
set -e

echo "Kamila entrypoint — waiting for Ollama..."
for i in $(seq 1 60); do
    if curl -s http://ollama:11434/api/tags >/dev/null 2>&1; then
        echo "Ollama is up."
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "Ollama did not become ready. Continuing without it."
    fi
    sleep 2
done

if ! curl -s http://ollama:11434/api/tags 2>/dev/null | grep -q '"kamila"'; then
    echo "Creating Kamila model from config/Modelfile..."
    if ollama create kamila -f config/Modelfile 2>/dev/null; then
        echo "Kamila model created."
    else
        echo "Model creation failed (network/login may be required for gpt-oss:120b-cloud)."
    fi
fi

echo "Launching Kamila TUI..."
exec /kamila/bin/kamila "$@"