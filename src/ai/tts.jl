"""
Kamila Text-to-Speech (TTS) Module
Handles voice output for terminal responses with formatting cleanup.
"""

module TTS

using JSON

export speak

"""
Clean text for speech synthesis by removing Markdown, JSON, and special characters.
Ensures Kamila "talks normal" as requested.
"""
function clean_for_speech(text::AbstractString)
    # 1. Remove JSON blocks (common in agent tool calls)
    text = replace(text, r"```(?:json)?\s*\{.*?\}\s*```"s => "")
    text = replace(text, r"```(?:json)?\s*\[.*?\]\s*```"s => "")

    # 2. Remove any other code blocks
    text = replace(text, r"```.*?```"s => "")

    # 3. Remove inline code
    text = replace(text, r"`.*?`" => "")

    # 4. Remove Markdown headers (e.g., # Summary) - User requested to exclude headers
    text = replace(text, r"^\s*#+\s+.*$"m => "")

    # 5. Remove Bold/Italic formatting
    text = replace(text, r"\*\*+(.*?)\*\*+" => s"\1")
    text = replace(text, r"__+(.*?)__+" => s"\1")
    text = replace(text, r"\*(.*?)\*" => s"\1")
    text = replace(text, r"_(.*?)_" => s"\1")

    # 6. Clean up links [text](url) -> just the text
    text = replace(text, r"\[(.*?)\]\(.*?\)" => s"\1")

    # 7. Remove list markers
    text = replace(text, r"^\s*[-*+]\s+"m => "")
    text = replace(text, r"^\s*\d+\.\s+"m => "")

    # 8. Remove emojis and symbols that sound strange when spoken
    # \p{So} matches Symbols, Other (including most emojis)
    text = replace(text, r"\p{So}" => "")

    # 9. Handle multi-line text: replace newlines with a pause (dot and space)
    # Split into lines, strip them, and filter out empty ones
    lines = split(text, '\n')
    lines = filter(!isempty, map(strip, lines))
    text = join(lines, ". ")

    # 10. Final cleanup: strip and normalize whitespace
    text = strip(text)
    text = replace(text, r"\s+" => " ")
    # Avoid double dots if lines already ended with punctuation
    text = replace(text, r"\.\s*\." => ".")

    return text
end

"""
Speak text using system TTS tools.
Runs asynchronously to avoid blocking the main terminal interface.
"""
function speak(text::AbstractString)
    cleaned = clean_for_speech(text)

    # Don't try to speak empty strings
    if isempty(cleaned) || length(cleaned) < 2
        return
    end

    # For debugging: print the cleaned text that will be spoken


    # Run in background to keep terminal responsive
    @async begin
        try
            # Try piper 'say' command first
            piper_path = expanduser("~/.local/bin/piper-wrapper")
            run(pipeline(`$piper_path "$cleaned"`, stdout = devnull, stderr = devnull))
        catch
            try
                # Try spd-say (Speech Dispatcher - standard Linux desktop TTS)
                run(`spd-say -t female2 "$cleaned"`)
            catch
                try
                    # Fallback to espeak-ng
                    run(`espeak-ng "$cleaned"`)
                catch
                    try
                        # Fallback to espeak
                        run(`espeak "$cleaned"`)
                    catch
                        # If no TTS engine is found, fail silently
                    end
                end
            end
        end
    end
end

end # module
