"""
Desktop Organization Module for Kamila
Helps organize and manage desktop files efficiently
"""

module Desktop

using ..FileAccess

export organize_desktop, suggest_desktop_organization, clean_desktop, get_desktop_stats

"""
Get desktop files with statistics
"""
function get_desktop_stats()
    desktop_path = joinpath(homedir(), "Desktop")
    
    if !isdir(desktop_path)
        return Dict("error" => "Desktop directory not found")
    end
    
    try
        files = FileAccess.safe_list_directory(desktop_path)
        
        # Separate files and directories
        file_list = String[]
        dir_list = String[]
        
        for item in files
            if isfile(item)
                push!(file_list, basename(item))
            elseif isdir(item)
                push!(dir_list, basename(item))
            end
        end
        
        # Count by file type
        file_types = Dict{String, Int}()
        total_size = 0
        
        for file in file_list
            ext = lowercase(splitext(file)[2])
            if isempty(ext)
                ext = "no_extension"
            end
            file_types[ext] = get(file_types, ext, 0) + 1
            
            try
                file_path = joinpath(desktop_path, file)
                total_size += stat(file_path).size
            catch
            end
        end
        
        return Dict(
            "total_items" => length(files),
            "files" => length(file_list),
            "directories" => length(dir_list),
            "file_types" => file_types,
            "total_size_bytes" => total_size,
            "total_size_mb" => round(total_size / 1024^2, digits=2),
            "desktop_path" => desktop_path
        )
    catch e
        return Dict("error" => "Failed to get desktop stats: $e")
    end
end

"""
Suggest organization for desktop files
"""
function suggest_desktop_organization()
    stats = get_desktop_stats()
    
    if haskey(stats, "error")
        return stats["error"]
    end
    
    suggestions = []
    push!(suggestions, "🖥️  Desktop Organization Suggestions")
    push!(suggestions, "")
    push!(suggestions, "📊 Current Status:")
    push!(suggestions, "  • Total items: $(stats["total_items"])")
    push!(suggestions, "  • Files: $(stats["files"])")
    push!(suggestions, "  • Directories: $(stats["directories"])")
    push!(suggestions, "  • Total size: $(stats["total_size_mb"]) MB")
    push!(suggestions, "")
    
    # Suggest folder creation based on file types
    push!(suggestions, "📁 Suggested Folder Organization:")
    
    file_types = stats["file_types"]
    
    if haskey(file_types, ".pdf")
        push!(suggestions, "  • Create 'Documents' folder for PDF files ($(file_types[".pdf"]) files)")
    end
    
    if haskey(file_types, ".jpg") || haskey(file_types, ".png") || haskey(file_types, ".gif")
        img_count = get(file_types, ".jpg", 0) + get(file_types, ".png", 0) + get(file_types, ".gif", 0)
        push!(suggestions, "  • Create 'Images' folder for picture files ($img_count files)")
    end
    
    if haskey(file_types, ".zip") || haskey(file_types, ".tar") || haskey(file_types, ".rar")
        arch_count = get(file_types, ".zip", 0) + get(file_types, ".tar", 0) + get(file_types, ".rar", 0)
        push!(suggestions, "  • Create 'Archives' folder for compressed files ($arch_count files)")
    end
    
    if haskey(file_types, ".py") || haskey(file_types, ".jl") || haskey(file_types, ".js")
        code_count = get(file_types, ".py", 0) + get(file_types, ".jl", 0) + get(file_types, ".js", 0)
        push!(suggestions, "  • Create 'Codes' folder for programming files ($code_count files)")
    end
    
    if stats["total_items"] > 20
        push!(suggestions, "")
        push!(suggestions, "⚠️  Your desktop has $(stats["total_items"]) items!")
        push!(suggestions, "   Consider organizing to improve productivity.")
    end
    
    return join(suggestions, "\n")
end

"""
Organize desktop files automatically
"""
function organize_desktop(;create_folders::Bool=true, move_files::Bool=false)
    desktop_path = joinpath(homedir(), "Desktop")
    
    if !isdir(desktop_path)
        return Dict("success" => false, "error" => "Desktop directory not found")
    end
    
    try
        stats = get_desktop_stats()
        file_types = stats["file_types"]
        
        # Define organization rules
        organization_rules = Dict(
            "Images" => [".jpg", ".jpeg", ".png", ".gif", ".bmp", ".svg"],
            "Documents" => [".pdf", ".doc", ".docx", ".txt", ".rtf"],
            "Archives" => [".zip", ".tar", ".gz", ".rar", ".7z"],
            "Codes" => [".py", ".jl", ".js", ".html", ".css", ".cpp", ".c", ".h"],
            "Videos" => [".mp4", ".avi", ".mkv", ".mov", ".wmv"],
            "Audio" => [".mp3", ".wav", ".flac", ".aac", ".ogg"]
        )
        
        moved_files = 0
        created_folders = 0
        
        if create_folders
            # Create organization folders
            for folder_name in keys(organization_rules)
                folder_path = joinpath(desktop_path, folder_name)
                if !isdir(folder_path)
                    FileAccess.safe_create_directory(folder_path)
                    created_folders += 1
                end
            end
        end
        
        if move_files
            # Move files to appropriate folders
            files = FileAccess.safe_list_directory(desktop_path)
            
            for file in files
                file_path = joinpath(desktop_path, file)
                
                if isfile(file_path)
                    ext = lowercase(splitext(file)[2])
                    
                    for (folder_name, extensions) in organization_rules
                        if ext in extensions
                            dest_folder = joinpath(desktop_path, folder_name)
                            dest_path = joinpath(dest_folder, file)
                            
                            if !isfile(dest_path)  # Avoid overwriting
                                FileAccess.safe_move_file(file_path, dest_path)
                                moved_files += 1
                            end
                            break
                        end
                    end
                end
            end
        end
        
        return Dict(
            "success" => true,
            "created_folders" => created_folders,
            "moved_files" => moved_files,
            "message" => "Desktop organization completed. Created $created_folders folders, moved $moved_files files."
        )
    catch e
        return Dict("success" => false, "error" => "Failed to organize desktop: $e")
    end
end

"""
Clean desktop by moving old files to appropriate folders
"""
function clean_desktop(;days_old::Int=30)
    desktop_path = joinpath(homedir(), "Desktop")
    
    if !isdir(desktop_path)
        return Dict("success" => false, "error" => "Desktop directory not found")
    end
    
    try
        files = FileAccess.safe_list_directory(desktop_path)
        cleaned_files = 0
        
        cutoff_time = time() - (days_old * 24 * 60 * 60)  # days_old days ago
        
        for file in files
            file_path = joinpath(desktop_path, file)
            
            if isfile(file_path)
                file_time = stat(file_path).mtime
                
                if file_time < cutoff_time
                    # Suggest moving to appropriate folder
                    ext = lowercase(splitext(file)[2])
                    
                    folder_suggestions = Dict(
                        ".pdf" => "Documents", ".doc" => "Documents", ".txt" => "Documents",
                        ".jpg" => "Images", ".png" => "Images", ".gif" => "Images",
                        ".zip" => "Archives", ".tar" => "Archives", ".rar" => "Archives",
                        ".py" => "Codes", ".jl" => "Codes", ".js" => "Codes"
                    )
                    
                    suggested_folder = get(folder_suggestions, ext, "Misc")
                    
                    println("📁 Suggestion: Move '$file' to '$suggested_folder' folder (last modified: $(Dates.format(Dates.unix2datetime(file_time), "yyyy-mm-dd HH:MM")))")
                    cleaned_files += 1
                end
            end
        end
        
        return Dict(
            "success" => true,
            "cleaned_suggestions" => cleaned_files,
            "message" => "Found $cleaned_files files that could be organized (older than $days_old days)."
        )
    catch e
        return Dict("success" => false, "error" => "Failed to clean desktop: $e")
    end
end

"""
Get AI-powered organization suggestions
"""
function get_ai_organization_suggestions()
    stats = get_desktop_stats()
    
    if haskey(stats, "error")
        return stats["error"]
    end
    
    # Get list of all files
    desktop_path = joinpath(homedir(), "Desktop")
    files = try
        [basename(f) for f in FileAccess.safe_list_directory(desktop_path) if isfile(joinpath(desktop_path, f))]
    catch
        String[]
    end
    
    if isempty(files)
        return "🖥️  Desktop is empty. Great job staying organized!"
    end
    
    # Basic AI-like suggestions (no dependency on OllamaInterface for now)
    ai_suggestions = "💡 Basic Organization Recommendations:
    • Group files by type: Create folders for Documents, Images, Codes, Archives
    • Use descriptive names for files
    • Archive old files to keep desktop clean
    • Consider using date-based folders for better organization"
    
    result = []
    push!(result, "🤖 AI-Powered Desktop Organization")
    push!(result, "")
    push!(result, ai_suggestions)
    
    return join(result, "\n")
end

"""
Generate desktop health report
"""
function generate_desktop_health_report()
    stats = get_desktop_stats()
    
    if haskey(stats, "error")
        return "❌ Desktop health check failed: $(stats["error"])"
    end
    
    report = []
    push!(report, "🏥 Desktop Health Report")
    push!(report, "")
    push!(report, "📊 Statistics:")
    push!(report, "  • Total items: $(stats["total_items"])")
    push!(report, "  • Files: $(stats["files"])")
    push!(report, "  • Folders: $(stats["directories"])")
    push!(report, "  • Storage used: $(stats["total_size_mb"]) MB")
    push!(report, "")
    
    # Health assessment
    health_score = 100
    issues = []
    
    if stats["total_items"] > 50
        health_score -= 20
        push!(issues, "Too many items on desktop ($(stats["total_items"]))")
    elseif stats["total_items"] > 30
        health_score -= 10
        push!(issues, "Desktop getting cluttered ($(stats["total_items"]))")
    end
    
    if stats["total_size_mb"] > 500
        health_score -= 15
        push!(issues, "Large amount of storage used ($(stats["total_size_mb"]) MB)")
    end
    
    # Determine health status
    if health_score >= 90
        status = "🟢 Excellent"
    elseif health_score >= 70
        status = "🟡 Good"
    elseif health_score >= 50
        status = "🟠 Fair"
    else
        status = "🔴 Poor"
    end
    
    push!(report, "🎯 Health Score: $health_score/100 ($status)")
    
    if !isempty(issues)
        push!(report, "")
        push!(report, "⚠️  Issues identified:")
        for issue in issues
            push!(report, "  • $issue")
        end
    end
    
    push!(report, "")
    push!(report, "💡 Recommendations:")
    if stats["total_items"] > 30
        push!(report, "  • Consider organizing files into folders")
        push!(report, "  • Move old files to appropriate directories")
    end
    
    if stats["total_size_mb"] > 200
        push!(report, "  • Review large files and archive if necessary")
    end
    
    push!(report, "  • Use AI suggestions for intelligent organization")
    
    return join(report, "\n")
end

end # module
