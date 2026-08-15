"""
Screenshot — capture the screen and describe it via `Vision` (08.3).

Privacy posture: the screenshot is written to a temp file inside an allowed
directory, described by the vision model, and the image is deleted before the
description is returned. The image bytes never reach the prompt — only the text
description does. Every capture is logged.

Capture tools (feature-detected): `scrot`, `import` (ImageMagick), or `grim`
(Wayland). `KAMILA_SCREENSHOT_CMD` overrides with a full command whose last
argument is the output path (used by tests to point at a fake capture script).
"""

module Screenshot

using ..Errors
using ..FileAccess
using ..Vision
using ..KamilaLog

export screenshot_description, capture_screenshot

"""
    capture_screenshot() -> String

Capture the screen to a `.png` temp file inside an allowed directory and return
its path. Throws a categorized `:external` KamilaError when no capture tool is
available or the capture fails.
"""
function capture_screenshot()
    cmd = _capture_cmd()
    cmd === nothing && throw(
        Errors.KamilaError(
            :external,
            "No screenshot tool available (scrot/import/grim). Install one to capture the screen.",
        ),
    )

    allowed = FileAccess.get_allowed_directories()
    isempty(allowed) && throw(Errors.KamilaError(:external, "No allowed directory for screenshot capture"))
    out = joinpath(allowed[1], "kamila_shot_$(string(time_ns())).png")

    try
        run(pipeline(`$cmd $out`, stdout = devnull, stderr = devnull))
    catch e
        throw(Errors.KamilaError(:external, "Screenshot failed: $(sprint(showerror, e))"))
    end
    isfile(out) || throw(Errors.KamilaError(:external, "Screenshot produced no image"))
    KamilaLog.info(
        "screenshot.captured";
        mod = "screenshot",
        fields = Dict("path" => basename(out), "bytes" => stat(out).size),
    )
    return out
end

function _capture_cmd()
    # Explicit disable for headless/no-capture setups (and tests of the
    # no-availability path): `KAMILA_SCREENSHOT_CMD=none`.
    override = get(ENV, "KAMILA_SCREENSHOT_CMD", "")
    if !isempty(override)
        return lowercase(override) == "none" ? nothing : override
    end
    for tool in ("scrot", "import", "grim")
        Sys.which(tool) !== nothing && return tool
    end
    return nothing
end

"""
    screenshot_description() -> String

Capture the screen, describe it with the vision model, delete the image, and
return only the text description. Throws a categorized KamilaError on failure.
"""
function screenshot_description()
    shot = capture_screenshot()
    try
        return Vision.describe_image(shot)
    finally
        isfile(shot) && rm(shot; force = true)
    end
end

end # module