"""
Code Tracker Module for Kamila
Tracks file changes in projects using content hashing
"""

module CodeTracker

using SHA
using JSON
using Dates

export track_directory, check_status, update_snapshot, get_tracker_info

const TRACKER_FILE = ".kamila_tracker.json"
const IGNORE_DIRS = [".git", ".kamila", "build", "dist", "node_modules", "__pycache__"]

struct FileState
    path::String
    hash::String
    mtime::Float64
    size::Int
end

"""
Calculate SHA256 hash of a file
"""
function calculate_file_hash(filepath::String)
    try
        open(filepath) do f
            return bytes2hex(sha256(f))
        end
    catch
        return ""
    end
end

"""
Scan directory and return a dictionary of FileStates
"""
function scan_directory(dir_path::String)
    states = Dict{String, Dict}()
    
    # Walk through directory
    for (root, dirs, files) in walkdir(dir_path)
        # Filter ignored directories
        filter!(d -> !any(x -> occursin(x, joinpath(root, d)), IGNORE_DIRS) && !startswith(d, "."), dirs)
        
        for file in files
            if startswith(file, ".") || file == TRACKER_FILE
                continue
            end
            
            full_path = joinpath(root, file)
            rel_path = relpath(full_path, dir_path)
            
            # Skip if path contains ignored dirs
            if any(x -> occursin("/$x/", "/$rel_path/"), IGNORE_DIRS)
                continue
            end
            
            try
                st = stat(full_path)
                file_hash = calculate_file_hash(full_path)
                
                states[rel_path] = Dict(
                    "hash" => file_hash,
                    "mtime" => st.mtime,
                    "size" => st.size,
                    "last_checked" => string(now())
                )
            catch e
                # Skip unreadable files
            end
        end
    end
    
    return states
end

"""
Initialize or Update tracking for a directory
"""
function track_directory(dir_path::String)
    dir_path = abspath(expanduser(dir_path))
    
    if !isdir(dir_path)
        return (false, "Directory not found: $dir_path")
    end
    
    println("🔍 Scanning files in $dir_path...")
    current_states = scan_directory(dir_path)
    
    tracker_data = Dict(
        "created_at" => string(now()),
        "last_scan" => string(now()),
        "root_path" => dir_path,
        "files" => current_states
    )
    
    tracker_path = joinpath(dir_path, TRACKER_FILE)
    
    try
        write(tracker_path, JSON.json(tracker_data, 2))
        return (true, "Successfully tracked $(length(current_states)) files.")
    catch e
        return (false, "Failed to save tracker file: $e")
    end
end

"""
Check for changes since last snapshot
"""
function check_status(dir_path::String)
    dir_path = abspath(expanduser(dir_path))
    tracker_path = joinpath(dir_path, TRACKER_FILE)
    
    if !isfile(tracker_path)
        return (false, "No tracker found. Run 'Start Tracking' first.", Dict())
    end
    
    try
        # Load previous state
        saved_data = JSON.parse(read(tracker_path, String))
        saved_files = saved_data["files"]
        
        # Scan current state
        current_files = scan_directory(dir_path)
        
        changes = Dict(
            "modified" => String[],
            "added" => String[],
            "deleted" => String[],
            "stats" => Dict(
                "total_scanned" => length(current_files),
                "last_snapshot" => saved_data["last_scan"]
            )
        )
        
        # Check for modifications and additions
        for (path, info) in current_files
            if haskey(saved_files, path)
                # Check if modified
                if saved_files[path]["hash"] != info["hash"]
                    push!(changes["modified"], path)
                end
            else
                # New file
                push!(changes["added"], path)
            end
        end
        
        # Check for deletions
        for (path, _) in saved_files
            if !haskey(current_files, path)
                push!(changes["deleted"], path)
            end
        end
        
        return (true, "Scan complete", changes)
    catch e
        return (false, "Error checking status: $e", Dict())
    end
end

"""
Update the snapshot to current state (acknowledge changes)
"""
function update_snapshot(dir_path::String)
    return track_directory(dir_path)
end

"""
Get basic info about tracker
"""
function get_tracker_info(dir_path::String)
    tracker_path = joinpath(abspath(expanduser(dir_path)), TRACKER_FILE)
    if isfile(tracker_path)
        try
            data = JSON.parse(read(tracker_path, String))
            return true, data
        catch
        end
    end
    return false, Dict()
end

end # module
