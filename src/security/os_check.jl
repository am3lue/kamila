"""
OS Verification Module for Kamila
Ensures Kamila only runs on Linux operating systems
"""

module OSCheck

export is_linux_os, verify_os_compatibility, get_system_info

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
Check if running on Arch Linux specifically
"""
function is_arch_linux()
    if !is_linux_os()
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

end # module
