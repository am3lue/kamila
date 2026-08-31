"""
OS Verification Module for Kamila
Ensures Kamila only runs on Linux operating systems
"""

module OSCheck

export is_linux_os,
    verify_os_compatibility,
    get_system_info,
    get_linux_distro,
    is_arch_linux,
    arch_restriction_check,
    verify_arch_restriction,
    generate_compatibility_report,
    enforce_platform_restriction

"""
Check if current OS is Linux
"""
function is_linux_os()
    return Sys.islinux()
end

"""
Verify OS compatibility and exit if not Linux
"""
function verify_os_compatibility()
    if !is_linux_os()
        println("❌ Kamila Error: Operating System Not Supported")
        println()
        println("Kamila is designed exclusively for Linux operating systems.")
        println("Current OS: $(string(Sys.KERNEL)) $(readchomp(`uname -r`))")
        println()
        println("Supported platforms:")
        println("  ✅ Linux (all distributions)")
        println("  ❌ Windows (not supported)")
        println("  ❌ macOS (not supported)")
        println("  ❌ Other platforms (not supported)")
        println()
        println("For the best experience, Kamila is optimized for Arch Linux.")
        println("Please run Kamila on a Linux system to continue.")
        exit(1)
    end

    println("✅ OS Check Passed: $(string(Sys.KERNEL)) $(readchomp(`uname -r`))")
    return true
end

"""
Get detailed system information
"""
function get_system_info()
    return Dict(
        "os_name" => string(Sys.KERNEL),
        "kernel_version" => string(readchomp(`uname -r`)),
        "arch" => Sys.ARCH,
        "word_size" => Sys.WORD_SIZE,
        "cpu_threads" => Sys.CPU_THREADS,
        "total_memory_gb" => round(Sys.total_memory() / 1024^3, digits = 2),
        "free_memory_gb" => round(Sys.free_memory() / 1024^3, digits = 2),
        "uptime" => Sys.uptime(),
        "is_linux" => is_linux_os(),
    )
end

"""
Check if running on Arch Linux specifically.

Honors the `KAMILA_FORCE_ARCH` env override (`true`/`false`) so the decision
can be tested deterministically on any host.
"""
function is_arch_linux()
    if !is_linux_os()
        return false
    end

    forced = lowercase(get(ENV, "KAMILA_FORCE_ARCH", ""))
    if forced in ("true", "1", "yes")
        return true
    elseif forced in ("false", "0", "no")
        return false
    end

    try
        # Check for Arch Linux specific files
        return isfile("/etc/arch-release") ||
               isfile("/etc/os-release") &&
               occursin("Arch", read("/etc/os-release", String))
    catch
        return false
    end
end

"""
Get Linux distribution information
"""
function get_linux_distro()
    if !is_linux_os()
        return "Unknown"
    end

    try
        # Try to read distribution info from /etc/os-release
        if isfile("/etc/os-release")
            content = read("/etc/os-release", String)
            for line in split(content, "\n")
                if startswith(line, "PRETTY_NAME=")
                    return strip(replace(line, "PRETTY_NAME=" => ""), '"')
                end
            end
        end

        # Fallback to checking specific files
        if isfile("/etc/arch-release")
            return "Arch Linux"
        elseif isfile("/etc/debian_version")
            return "Debian/Ubuntu"
        elseif isfile("/etc/redhat-release")
            return "Red Hat/Fedora"
        elseif isfile("/etc/opensuse-release")
            return "openSUSE"
        else
            return "Unknown Linux"
        end
    catch
        return "Unknown Linux"
    end
end

"""
Generate system compatibility report
"""
function generate_compatibility_report()
    info = get_system_info()
    distro = get_linux_distro()
    is_arch = is_arch_linux()

    report = []
    push!(report, "🔍 System Compatibility Report")
    push!(report, "")
    push!(report, "Operating System:")
    push!(report, "  • Name: $(info["os_name"])")
    push!(report, "  • Distribution: $distro")
    push!(report, "  • Kernel: $(info["kernel_version"])")
    push!(report, "  • Architecture: $(info["arch"])")
    push!(report, "  • Word Size: $(info["word_size"])-bit")
    push!(report, "")
    push!(report, "Hardware:")
    push!(report, "  • CPU Threads: $(info["cpu_threads"])")
    push!(report, "  • Total Memory: $(info["total_memory_gb"]) GB")
    push!(report, "  • Free Memory: $(info["free_memory_gb"]) GB")
    push!(report, "")
    push!(report, "Compatibility:")
    push!(report, "  • Linux Compatible: $(info["is_linux"] ? "✅ Yes" : "❌ No")")
    push!(
        report,
        "  • Arch Linux: $(is_arch ? "✅ Yes" : "⚠️  No (other distros supported)")",
    )
    push!(
        report,
        "  • Kamila Status: $(info["is_linux"] ? "✅ Fully Supported" : "❌ Not Supported")",
    )

    return join(report, "\n")
end

"""
Block execution if not on supported platform
"""
function enforce_platform_restriction()
    if !is_linux_os()
        verify_os_compatibility()  # This will exit with error message
    end
end

"""
    arch_restriction_mode() -> Symbol

Effective Arch-restriction mode: `:off` (default, best-effort only),
`:warn` (log + console warning on non-Arch), or `:strict` (hard exit on
non-Arch). Controlled by the `KAMILA_ARCH_RESTRICT` env var
(`off`/`warn`/`strict`, case-insensitive; any unrecognized value ⇒ `off`).
This is the "restrict heavily non-Arch users" switch: set `strict` to make
Kamila refuse to run outside Arch Linux.
"""
function arch_restriction_mode()
    raw = lowercase(get(ENV, "KAMILA_ARCH_RESTRICT", "off"))
    raw in ("strict", "warn") && return Symbol(raw)
    return :off
end

"""
    arch_restriction_check() -> :ok | :warn | :block

Pure decision function: returns `:ok` when running on Arch (or when the
restriction is `off`), `:warn` on non-Arch under `warn` mode, and `:block` on
non-Arch under `strict` mode. Never exits, so it is safe to call from tests.
See [`arch_restriction_mode`](@ref) for the mode switch.
"""
function arch_restriction_check()
    is_arch_linux() && return :ok
    mode = arch_restriction_mode()
    mode == :strict && return :block
    mode == :warn && return :warn
    return :ok
end

"""
    verify_arch_restriction() -> Bool

Applies the configured Arch restriction via [`arch_restriction_check`](@ref).
Returns `true` when the check allows running (Arch or `off`), `false`
otherwise (with a warning on non-Arch under `warn`). In `strict` mode prints
an error and calls `exit(1)`. Never throws.
"""
function verify_arch_restriction()
    check = arch_restriction_check()
    check == :ok && return true
    distro = get_linux_distro()
    msg = """
    Kamila is optimized for Arch Linux and is configured to restrict
    non-Arch systems.
      Detected distribution: $distro
    """
    if check == :block
        println("[error] Kamila: $msg")
        println("Set KAMILA_ARCH_RESTRICT=off to run on non-Arch systems.")
        exit(1)
    end
    println("[warn] Kamila: $msg")
    return false
end

end # module
