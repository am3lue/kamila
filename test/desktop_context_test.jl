"""
test/desktop_context_test.jl — Tests of the 08.3 desktop-awareness modules.

Covers: session feature-detection, active-window via mocked xdotool/swaymsg,
redacted clipboard capture, graceful degradation when tools are missing,
screenshot → vision description round-trip (with the image never leaking),
the desktop_status / screenshot_describe tools, and the bridge
desktop.status / desktop.screenshot / desktop.watch routes (watch off by
default; enabling emits a desktop.activity event).
"""

using Test
using JSON

using .Kamila
const DC = Kamila.DesktopContext
const SHOT = Kamila.Screenshot
const ERR = Kamila.Errors
const BR = Kamila.KamilaBridge
const MOCK = TEST_SANDBOX[]["mock_server"]

function parse_bridge_output(output::String)
    events = Dict{String,Any}[]
    for line in split(output, "\n")
        isempty(strip(line)) && continue
        try
            push!(events, JSON.parse(line))
        catch
        end
    end
    return events
end

function find_event(events, type::String)
    return filter(e -> get(e, "type", "") == type, events)
end

function write_script(name::String, body::String)
    path = joinpath(TEST_SANDBOX[]["allowed"], name)
    write(path, body)
    chmod(path, 0o755)
    return path
end

@testset "DesktopContext" begin
    @testset "session feature-detection" begin
        with_env(Dict("KAMILA_DESKTOP_SESSION" => "x11"), () -> begin
            @test DC.detect_session_type() == :x11
        end)
        with_env(Dict("KAMILA_DESKTOP_SESSION" => "wayland"), () -> begin
            @test DC.detect_session_type() == :wayland
        end)
        # No DISPLAY/WAYLAND and no override → unknown, never a crash.
        with_env(Dict("KAMILA_DESKTOP_SESSION" => nothing, "DISPLAY" => nothing, "WAYLAND_DISPLAY" => nothing, "XDG_SESSION_TYPE" => nothing), () -> begin
            @test DC.detect_session_type() == :unknown
        end)
    end

    @testset "active window via mocked xdotool (X11)" begin
        fake = write_script("fake_xdotool.sh", "#!/bin/sh\necho 'Terminal — Build'\n")
        with_env(
            Dict("KAMILA_DESKTOP_SESSION" => "x11", "KAMILA_ACTIVE_WINDOW_CMD" => fake),
            () -> begin
                @test DC.active_window_title() == "Terminal — Build"
            end,
        )
    end

    @testset "active window via mocked swaymsg (Wayland)" begin
        fake = write_script(
            "fake_swaymsg.sh",
            "#!/bin/sh\ncat <<'EOF'\n" *
            "{\"nodes\":[{\"focused\":false,\"name\":\"Output\",\"nodes\":[{\"focused\":true,\"name\":\"Editor\"}]}]}\nEOF\n",
        )
        with_env(
            Dict("KAMILA_DESKTOP_SESSION" => "wayland", "KAMILA_ACTIVE_WINDOW_CMD" => fake),
            () -> begin
                @test DC.active_window_title() == "Editor"
            end,
        )
    end

    @testset "missing tools degrade gracefully, never crash" begin
        with_env(
            Dict("KAMILA_DESKTOP_SESSION" => "wayland", "KAMILA_ACTIVE_WINDOW_CMD" => nothing),
            () -> begin
                # swaymsg isn't on this test host → nothing, not an exception.
                @test DC.active_window_title() === nothing
                @test DC.clipboard_text() === nothing
            end,
        )
        # Unknown session → every field degrades.
        with_env(Dict("KAMILA_DESKTOP_SESSION" => "unknown"), () -> begin
            st = DC.desktop_status()
            @test st["session"] == "unknown"
            @test get(st, "active_window", "sentinel") === nothing
            @test get(st, "clipboard", "sentinel") === nothing
        end)
    end

    @testset "clipboard is truncated and redacted" begin
        fake = write_script("fake_clip.sh", "#!/bin/sh\necho 'ghp_abcdef0123456789abcdef0123456789 and notes'\n")
        with_env(
            Dict("KAMILA_DESKTOP_SESSION" => "x11", "KAMILA_CLIPBOARD_CMD" => fake),
            () -> begin
                clip = DC.clipboard_text()
                @test occursin("notes", clip)
                @test !occursin("ghp_abcdef", clip)
                @test occursin("[redacted]", clip)
            end,
        )

        # Over-long clipboard is truncated to 4 KB.
        big = write_script("fake_clip_big.sh", "#!/bin/sh\nhead -c 9000 /dev/zero | tr '\\0' 'x'\n")
        with_env(
            Dict("KAMILA_DESKTOP_SESSION" => "x11", "KAMILA_CLIPBOARD_CMD" => big),
            () -> begin
                clip = DC.clipboard_text()
                @test clip !== nothing
                @test length(clip) <= 4096 + 64
            end,
        )
    end

    @testset "watch is off by default and toggles explicitly" begin
        with_env(Dict("KAMILA_DESKTOP_SESSION" => "unknown"), () -> begin
            @test DC.watch_enabled() == false
            @test get(DC.desktop_status(), "watch_enabled", nothing) == false
            DC.set_watch_enabled!(true)
            @test DC.watch_enabled() == true
            DC.set_watch_enabled!(false)
        end)
    end

    @testset "desktop_status_tool returns a JSON snapshot" begin
        with_env(
            Dict("KAMILA_DESKTOP_SESSION" => "x11", "KAMILA_ACTIVE_WINDOW_CMD" => write_script("fake_xd.sh", "#!/bin/sh\necho 'Firefox'\n")),
            () -> begin
                out = Kamila.AgentTools.execute_tool("desktop_status", Dict())
                @test occursin("Desktop context", out)
                @test occursin("Firefox", out)
            end,
        )
    end

    @testset "screenshot → vision description, image never leaks" begin
        OllamaMockServer.set_script!(MOCK;
            chat_lines = [OllamaMockServer.chat_line(content = "A desktop with a code editor.", done = true)],
        )
        # A minimal PNG fixture the fake capture script "produces".
        png = joinpath(TEST_SANDBOX[]["allowed"], "shot.png")
        write(png, UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00])
        fake = write_script("fake_scrot.sh", "#!/bin/sh\ncp \"\$(dirname \"\$1\")/shot.png\" \"\$1\"\n")

        with_env(Dict("KAMILA_SCREENSHOT_CMD" => fake), () -> begin
            desc = SHOT.screenshot_description()
            @test occursin("code editor", desc)
        end)

        # The temp screenshot is deleted after description — nothing remains.
        leftovers = filter(f -> startswith(f, "kamila_shot_"), readdir(TEST_SANDBOX[]["allowed"]))
        @test isempty(leftovers)
    end

    @testset "no screenshot tool yields :external, never a guess" begin
        with_env(Dict("KAMILA_SCREENSHOT_CMD" => "none"), () -> begin
            err = try
                SHOT.capture_screenshot()
                nothing
            catch e
                e
            end
            @test err isa ERR.KamilaError
            @test ERR.error_category(err) == :external
        end)
    end

    @testset "bridge desktop.status / desktop.watch / desktop.screenshot routes" begin
        with_env(
            Dict("KAMILA_DESKTOP_SESSION" => "unknown"),
            () -> begin
                out = capture_stdout() do
                    BR.dispatch(
                        Dict(
                            "type" => "request",
                            "id" => "ds1",
                            "method" => "desktop.status",
                            "params" => Dict(),
                        ),
                    )
                end
                events = parse_bridge_output(out)
                @test events[1]["type"] == "response"
                @test get(events[1]["result"], "session", "") == "unknown"

                # Watch off → on → off; enabling publishes a desktop.activity
                # event on the bus (06.1 watcher consumes it).
                Kamila.Events.clear_queue!()
                out = capture_stdout() do
                    BR.dispatch(
                        Dict(
                            "type" => "request",
                            "id" => "dw1",
                            "method" => "desktop.watch",
                            "params" => Dict("enable" => true),
                        ),
                    )
                end
                events = parse_bridge_output(out)
                @test events[1]["type"] == "response"
                @test events[1]["result"]["watch_enabled"] == true
                activity = Kamila.Events.drain(10)
                @test any(e -> string(get(e, "kind", "")) == "desktop.activity", activity)

                out = capture_stdout() do
                    BR.dispatch(
                        Dict(
                            "type" => "request",
                            "id" => "dw2",
                            "method" => "desktop.watch",
                            "params" => Dict("enable" => false),
                        ),
                    )
                end
                events = parse_bridge_output(out)
                @test events[1]["result"]["watch_enabled"] == false

                # Screenshot route: mocked capture + vision → text description.
                OllamaMockServer.set_script!(MOCK;
                    chat_lines = [OllamaMockServer.chat_line(content = "A browser window with a search bar.", done = true)],
                )
                fake = write_script("fake_scrot2.sh", "#!/bin/sh\ncp \"\$(dirname \"\$1\")/shot.png\" \"\$1\"\n")
                with_env(Dict("KAMILA_SCREENSHOT_CMD" => fake), () -> begin
                    out = capture_stdout() do
                        BR.dispatch(
                            Dict(
                                "type" => "request",
                                "id" => "dsh1",
                                "method" => "desktop.screenshot",
                                "params" => Dict(),
                            ),
                        )
                    end
                    events = parse_bridge_output(out)
                    @test events[1]["type"] == "response"
                    @test occursin("search bar", get(events[1]["result"], "description", ""))
                end)
            end,
        )
    end
end