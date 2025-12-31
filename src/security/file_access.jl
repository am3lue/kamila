"""
File Access Security Module for Kamila
Ensures all file operations are restricted to allowed directories only
"""

module FileAccess

using ..Kamila
using ..OSCheck

export is_path_allowed, safe_read_file, safe_write_file, safe_list_directory, 
       safe_create_directory, safe_delete_file, safe_move_file, explain_file_content

const ALLOWED_DIRS = Kamila.ALLOWED_DIRS

"""
Check if a given path is within allowed directories
"""
function is_path_allowed(path::String)
    expanded_path = abspath(expanduser(path))
    
    for allowed_dir in ALLOWED_DIRS
        allowed_expanded = abspath(expanduser(allowed_dir))
        if startswith(expanded_path, allowed_expanded)
            return true
        end
    end
    
    return false
end

"""
Validate and expand a file path, ensuring it's within allowed directories
"""
function validate_path(path::String)
    expanded_path = abspath(expanduser(path))
    
    if !is_path_allowed(expanded_path)
        error("Path '$path' is outside of allowed directories. Kamila can only access: $(join(ALLOWED_DIRS, ", "))")
    end
    
    return expanded_path
end

"""
Safely read a file with path validation
"""
function safe_read_file(path::String)
    try
        validated_path = validate_path(path)
        
        if !isfile(validated_path)
            error("File '$path' does not exist")
        end
        
        return read(validated_path, String)
    catch e
        throw(ErrorException("Failed to read file '$path': $e"))
    end
end

"""
Safely write to a file with path validation
"""
function safe_write_file(path::String, content::String)
    try
        validated_path = validate_path(path)
        
        # Ensure the directory exists
        dir_path = dirname(validated_path)
        if !isdir(dir_path)
            mkpath(dir_path)
        end
        
        write(validated_path, content)
        return true
    catch e
        throw(ErrorException("Failed to write file '$path': $e"))
    end
end

"""
Safely list directory contents with path validation
"""
function safe_list_directory(path::String=".")
    try
        validated_path = validate_path(path)
        
        if !isdir(validated_path)
            error("Directory '$path' does not exist")
        end
        
        return readdir(validated_path, join=true)
    catch e
        throw(ErrorException("Failed to list directory '$path': $e"))
    end
end

"""
Safely create a directory with path validation
"""
function safe_create_directory(path::String)
    try
        validated_path = validate_path(path)
        
        if isdir(validated_path)
            return true  # Directory already exists
        end
        
        mkpath(validated_path)
        return true
    catch e
        throw(ErrorException("Failed to create directory '$path': $e"))
    end
end

"""
Safely delete a file with path validation
"""
function safe_delete_file(path::String)
    try
        validated_path = validate_path(path)
        
        if !isfile(validated_path)
            error("File '$path' does not exist")
        end
        
        rm(validated_path)
        return true
    catch e
        throw(ErrorException("Failed to delete file '$path': $e"))
    end
end

"""
Safely move/rename a file with path validation
"""
function safe_move_file(source::String, destination::String)
    try
        source_validated = validate_path(source)
        dest_validated = validate_path(destination)
        
        if !isfile(source_validated)
            error("Source file '$source' does not exist")
        end
        
        # Ensure destination directory exists
        dest_dir = dirname(dest_validated)
        if !isdir(dest_dir)
            mkpath(dest_dir)
        end
        
        mv(source_validated, dest_validated)
        return true
    catch e
        throw(ErrorException("Failed to move file '$source' to '$destination': $e"))
    end
end

"""
Get file information safely
"""
function safe_stat_file(path::String)
    try
        validated_path = validate_path(path)
        
        if !isfile(validated_path) && !isdir(validated_path)
            error("Path '$path' does not exist")
        end
        
        return stat(validated_path)
    catch e
        throw(ErrorException("Failed to get info for '$path': $e"))
    end
end

"""
Check if a file or directory exists (safely)
"""
function safe_exists(path::String)
    try
        validated_path = validate_path(path)
        return ispath(validated_path)
    catch
        return false
    end
end

"""
Get allowed directories list
"""
function get_allowed_directories()
    return copy(ALLOWED_DIRS)
end

"""
Check if a path is a subdirectory of any allowed directory
"""
function is_subdirectory_allowed(path::String)
    expanded_path = abspath(expanduser(path))
    
    for allowed_dir in ALLOWED_DIRS
        allowed_expanded = abspath(expanduser(allowed_dir))
        if startswith(expanded_path, allowed_expanded)
            return true, allowed_expanded
        end
    end
    
    return false, ""
end

"""
Explain file content using AI (placeholder for Ollama integration)
"""
function explain_file_content(path::String)
    try
        content = safe_read_file(path)
        
        # This would integrate with Ollama to explain the file content
        # For now, return a simple explanation
        file_info = safe_stat_file(path)
        file_size = file_info.size
        
        explanation = []
        push!(explanation, "📄 File Analysis: $(basename(path))")
        push!(explanation, "  • Size: $(file_size) bytes")
        push!(explanation, "  • Type: $(get_file_type(path))")
        push!(explanation, "  • Content preview:")
        
        # Show first few lines
        lines = split(content, "\n")
        preview_lines = lines[1:min(5, length(lines))]
        for line in preview_lines
            push!(explanation, "    $(line)")
        end
        
        if length(lines) > 5
            push!(explanation, "    ... (and $(length(lines) - 5) more lines)")
        end
        
        return join(explanation, "\n")
    catch e
        throw(ErrorException("Failed to explain file '$path': $e"))
    end
end

"""
Get file type based on extension
"""
function get_file_type(path::String)
    ext = lowercase(splitext(path)[2])
    
    type_map = Dict(
        ".jl" => "Julia Source Code",
        ".py" => "Python Source Code", 
        ".js" => "JavaScript Source Code",
        ".html" => "HTML Web Page",
        ".css" => "CSS Stylesheet",
        ".md" => "Markdown Document",
        ".txt" => "Text Document",
        ".json" => "JSON Data File",
        ".xml" => "XML Data File",
        ".pdf" => "PDF Document",
        ".png" => "PNG Image",
        ".jpg" => "JPEG Image",
        ".gif" => "GIF Image",
        ".mp3" => "MP3 Audio",
        ".mp4" => "MP4 Video",
        ".zip" => "ZIP Archive",
        ".tar" => "TAR Archive"
    )
    
    return get(type_map, ext, "Unknown File")
end

"""
Generate security report for file operations
"""
function generate_security_report()
    report = []
    push!(report, "🔒 File Access Security Report")
    push!(report, "")
    push!(report, "Allowed Directories:")
    for dir in ALLOWED_DIRS
        push!(report, "  ✅ $dir")
    end
    push!(report, "")
    push!(report, "Security Status:")
    push!(report, "  • OS Check: $(OSCheck.is_linux_os() ? "✅ Passed" : "❌ Failed")")
    push!(report, "  • Path Validation: ✅ Enabled")
    push!(report, "  • Write Restrictions: ✅ Active")
    
    return join(report, "\n")
end

"""
Test file access security (for testing purposes)
"""
function test_security()
    println("🧪 Testing File Access Security...")
    
    # Test 1: Try to access allowed directory
    try
        desktop_path = joinpath(homedir(), "Desktop")
        if is_path_allowed(desktop_path)
            println("✅ Allowed directory access: PASSED")
        else
            println("❌ Allowed directory access: FAILED")
        end
    catch
        println("❌ Allowed directory access: ERROR")
    end
    
    # Test 2: Try to access restricted path
    try
        restricted_path = "/etc/passwd"
        if is_path_allowed(restricted_path)
            println("❌ Restricted path protection: FAILED")
        else
            println("✅ Restricted path protection: PASSED")
        end
    catch
        println("✅ Restricted path protection: PASSED")
    end
    
    # Test 3: Try to access home directory subdirectory
    try
        home_path = homedir()
        if is_path_allowed(home_path)
            println("✅ Home directory access: PASSED")
        else
            println("❌ Home directory access: FAILED")
        end
    catch
        println("❌ Home directory access: ERROR")
    end
end

end # module
