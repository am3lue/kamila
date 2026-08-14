"""
test/helpers.jl — shared test utilities for the Kamila test suite.

Provides:
  - `with_sandbox(f)`: sets up an isolated HOME + memory/config/chat paths for the
    duration of `f`, so Tier-1 "real" tests never touch the real user files.
  - `with_env(kv, f)`: temporarily set environment variables around `f`.
  - `MockHTTP`: a configurable, canned HTTP response object used by tests that must
    exercise network-shaped code paths without hitting the network.
"""

using Test
using JSON

"""
Run `f` inside a temporary sandbox: fresh HOME, memory/config/chat files, and an
allowed directory for FileAccess tests. Returns the sandbox info Dict.
"""
function with_sandbox(f::Function)
    root = mktempdir()
    allowed = joinpath(root, "allowed")
    mkpath(allowed)
    write(joinpath(allowed, "hello.txt"), "Hello from sandbox!")

    old_home = ENV["HOME"]
    old_mem = get(ENV, "KAMILA_MEMORY_FILE", nothing)
    old_cfg = get(ENV, "KAMILA_CONFIG_FILE", nothing)
    old_chat = get(ENV, "KAMILA_CHAT_HISTORY_FILE", nothing)
    old_allowed = get(ENV, "KAMILA_ALLOWED_DIRS", nothing)
    old_models = get(ENV, "KAMILA_MODELS_CONFIG", nothing)
    old_db = get(ENV, "KAMILA_DB", nothing)

    ENV["HOME"] = root
    ENV["KAMILA_ALLOWED_DIRS"] = allowed
    ENV["KAMILA_MEMORY_FILE"] = joinpath(root, "memory.json")
    ENV["KAMILA_CONFIG_FILE"] = joinpath(root, "config.json")
    ENV["KAMILA_CHAT_HISTORY_FILE"] = joinpath(root, "chat.json")
    ENV["KAMILA_MODELS_CONFIG"] = joinpath(root, "models.json")
    ENV["KAMILA_DB"] = joinpath(root, "kamila.db")

    info = Dict{String,Any}(
        "root" => root,
        "allowed" => allowed,
        "memory_file" => ENV["KAMILA_MEMORY_FILE"],
        "config_file" => ENV["KAMILA_CONFIG_FILE"],
        "chat_file" => ENV["KAMILA_CHAT_HISTORY_FILE"],
        "db_file" => ENV["KAMILA_DB"],
    )

    try
        f(info)
    finally
        ENV["HOME"] = old_home
        for (name, old) in [
            ("KAMILA_MEMORY_FILE", old_mem),
            ("KAMILA_CONFIG_FILE", old_cfg),
            ("KAMILA_CHAT_HISTORY_FILE", old_chat),
            ("KAMILA_ALLOWED_DIRS", old_allowed),
            ("KAMILA_MODELS_CONFIG", old_models),
            ("KAMILA_DB", old_db),
        ]
            old === nothing ? delete!(ENV, name) : ENV[name] = old
        end
        rm(root; recursive = true, force = true)
    end
end

"""
Run `f` with stdout redirected to a temp file, returning the captured output as
a String. (Julia's `redirect_stdout` does not accept IOBuffer in 1.12.)
"""
function capture_stdout(f::Function)
    mktemp() do path, io
        close(io)
        open(path, "w") do out_h
            redirect_stdout(() -> f(), out_h)
        end
        return read(path, String)
    end
end

"""
Run `f` with the given environment variables set, restoring them afterwards.
`kv` is a Dict of name => value; a value of `nothing` deletes the variable.
"""
function with_env(kv::AbstractDict, f::Function)
    saved = Dict{String,Union{String,Nothing}}()
    for (name, value) in kv
        name = String(name)
        saved[name] = get(ENV, name, nothing)
        value === nothing ? delete!(ENV, name) : ENV[name] = value
    end
    try
        f()
    finally
        for (name, old) in saved
            old === nothing ? delete!(ENV, name) : ENV[name] = old
        end
    end
end

"""
Delete the sandbox memory/config/chat/DB files so a fresh module state can be
re-initialized in the next test. Safe to call even if the files don't exist.
"""
function reset_sandbox_files!(info::AbstractDict)
    for key in ["memory_file", "config_file", "chat_file", "db_file"]
        path = get(info, key, nothing)
        path !== nothing && isfile(path) && rm(path; force = true)
    end
    # Also clean WAL/SHM files for DB
    db_path = get(info, "db_file", nothing)
    if db_path !== nothing
        for p in [db_path * "-wal", db_path * "-shm"]
            isfile(p) && rm(p; force = true)
        end
    end
    # Close DB handle if open
    if isdefined(Main, :Kamila) && isdefined(Main.Kamila, :MemoryDB)
        try
            Main.Kamila.MemoryDB.reset!()
        catch
        end
    end
end

"""
Reset the KamilaMemory module's backing file to a blank default structure.
Also resets the SQLite DB.
"""
function reset_memory_file!(memory_file::String)
    reset_memory_db!()
    isfile(memory_file) && rm(memory_file; force = true)
    default_memory = Dict(
        "user_alias" => "Test",
        "tasks" => [],
        "achievements" => [],
        "goals" => [],
        "usage_stats" => Dict(
            "useful_activities" => 0,
            "total_activities" => 0,
            "productivity_percentage" => 0.0,
        ),
        "last_updated" => "2026-01-01T00:00:00",
    )
    write(memory_file, JSON.json(default_memory))
end

function reset_memory_db!()
    if isdefined(Main, :Kamila) && isdefined(Main.Kamila, :MemoryDB)
        try
            Main.Kamila.MemoryDB.reset!()
        catch
        end
    end
    db_path = get(ENV, "KAMILA_DB", nothing)
    if db_path !== nothing
        for p in [db_path, db_path * "-wal", db_path * "-shm"]
            isfile(p) && rm(p; force = true)
        end
    end
end

"""
A canned HTTP response object with a status code and body.
`MockHTTP.get(url; kwargs...)` returns the first matching canned response or
throws a `MockHTTP.UnhandledRequestError`, making tests explicit about what was
served instead of silently returning empty bodies.
"""
module MockHTTP

export MockResponse, MockHTTPClient, mock_get

struct MockResponse
    status::Int
    body::String
end

struct UnhandledRequestError <: Exception
    url::String
end

Base.showerror(io::IO, e::UnhandledRequestError) =
    print(io, "MockHTTP: no canned response for '$(e.url)'")

mutable struct MockHTTPClient
    responses::Vector{Pair{String,MockResponse}}
    calls::Vector{Tuple{String,Dict}}
end

MockHTTPClient() = MockHTTPClient(Pair{String,MockResponse}[], Tuple{String,Dict}[])

function mock_get(client::MockHTTPClient, url::String; kwargs...)
    push!(client.calls, (url, Dict(kwargs)))
    for (pattern, response) in client.responses
        if occursin(pattern, url)
            return response
        end
    end
    throw(UnhandledRequestError(url))
end

end # module MockHTTP
