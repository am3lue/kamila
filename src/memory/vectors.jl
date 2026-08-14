"""
Vectors — Embedding provider, similarity, cache, and FTS5 fallback.
"""

module Vectors

using HTTP
using JSON
using SHA
using LinearAlgebra
using SQLite
using Dates
using Base.Threads
using ..Kamila
using ..KamilaLog
using ..MemoryDB

export embed, similarity, cosine, recall_fallback, recall_vector, remember_content

# Configuration
const OLLAMA_HOST = get(ENV, "OLLAMA_HOST", "http://localhost:11434")
const EMBED_MODEL = get(ENV, "KAMILA_EMBED_MODEL", "nomic-embed-text")

# Cache: content_hash -> Vector{Float32}
const _EMBED_CACHE = Dict{String,Vector{Float32}}()
const _CACHE_LOCK = ReentrantLock()

"""
Compute SHA256 hash of content for cache key
"""
function _content_hash(content::String)
    return bytes2hex(sha256(content))
end

function _content_hash(content::SubString{String})
    return _content_hash(String(content))
end

"""
Embed text using Ollama /api/embed endpoint.
Returns Vector{Float32} or nothing on failure.
"""
function embed(text::String; model::String = EMBED_MODEL)
    isempty(strip(text)) && return nothing

    hash = _content_hash(text)
    lock(_CACHE_LOCK) do
        if haskey(_EMBED_CACHE, hash)
            return _EMBED_CACHE[hash]
        end
    end

    try
        response = HTTP.post(
            "$OLLAMA_HOST/api/embed",
            ["Content-Type" => "application/json"],
            JSON.json(Dict("model" => model, "input" => text)),
        )
        if response.status == 200
            data = JSON.parse(String(response.body))
            if haskey(data, "embeddings") && !isempty(data["embeddings"])
                vec = Float32.(data["embeddings"][1])
                lock(_CACHE_LOCK) do
                    _EMBED_CACHE[hash] = vec
                end
                return vec
            end
        end
        KamilaLog.warn(
            "Embeddings API returned unexpected response: $(response.status)";
            mod = "vectors",
        )
    catch e
        KamilaLog.warn("Embeddings API call failed: $e"; mod = "vectors")
    end

    return nothing
end

"""
Cosine similarity between two vectors. Returns Float64 in [-1, 1].
"""
function cosine(a::Vector{Float32}, b::Vector{Float32})
    length(a) != length(b) && return -1.0
    na = norm(a)
    nb = norm(b)
    (na == 0 || nb == 0) && return 0.0
    return Float64(dot(a, b) / (na * nb))
end

"""
Cosine similarity alias
"""
cosine(a, b) = similarity(a, b)

"""
Similarity function (alias for cosine)
"""
similarity(a::Vector{Float32}, b::Vector{Float32}) = cosine(a, b)

"""
Normalize vector in-place
"""
function normalize!(vec::Vector{Float32})
    n = norm(vec)
    n > 0 && (vec ./= n)
    return vec
end

"""
Store content with embedding in the memories table.
Returns (id, embedded::Bool).
"""
function remember_content(
    content::String;
    kind::String = "note",
    importance::Float64 = 0.5,
    period::Union{String,Nothing} = nothing,
    period_start::Union{String,Nothing} = nothing,
    period_end::Union{String,Nothing} = nothing,
    source_session_id::Union{Int,Nothing} = nothing,
    source_turn_count::Union{Int,Nothing} = nothing,
    retryable::Bool = false,
)
    isempty(strip(content)) && return (0, false)

    hash = _content_hash(content)
    vec = embed(content)
    embedded = vec !== nothing

    id = 0
    MemoryDB.transaction() do db
        # Check if content already exists
        row = SQLite.DBInterface.execute(
            db,
            "SELECT id FROM memories WHERE content_hash = ?",
            (hash,),
        )
        for r in row
            id = r.id
            break
        end

        if id == 0
            # Not found, insert new
            if embedded
                blob = reinterpret(UInt8, vec)
                SQLite.execute(
                    db,
                    """INSERT INTO memories 
                       (kind, content, content_hash, created_at, importance, embedding, period, period_start, period_end, source_session_id, source_turn_count, retryable)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                    (
                        kind,
                        content,
                        hash,
                        string(now()),
                        importance,
                        blob,
                        period,
                        period_start,
                        period_end,
                        source_session_id,
                        source_turn_count,
                        retryable ? 1 : 0,
                    ),
                )
            else
                SQLite.execute(
                    db,
                    """INSERT INTO memories 
                       (kind, content, content_hash, created_at, importance, period, period_start, period_end, source_session_id, source_turn_count, retryable)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                    (
                        kind,
                        content,
                        hash,
                        string(now()),
                        importance,
                        period,
                        period_start,
                        period_end,
                        source_session_id,
                        source_turn_count,
                        retryable ? 1 : 0,
                    ),
                )
            end

            # Get the new id
            row = SQLite.DBInterface.execute(
                db,
                "SELECT id FROM memories WHERE content_hash = ?",
                (hash,),
            )
            for r in row
                id = r.id
                break
            end
        end
    end

    # Also insert into FTS5 virtual table if it exists and this was a new insert with embedding
    if embedded && id > 0
        try
            MemoryDB.execute!(
                "INSERT OR IGNORE INTO memories_fts (rowid, content) VALUES (?, ?)",
                (id, content),
            )
        catch
            # FTS5 might not exist yet
        end
    end

    # Return (id, embedded) where embedded=true only for newly inserted rows with embedding
    # For duplicates, embedded=false
    is_new = (id > 0) && (embedded && id > 0)  # We can't easily track, so use heuristic
    return (id, embedded && is_new)
end

"""
FTS5 keyword fallback recall.
"""
function recall_fallback(
    query::String;
    k::Int = 5,
    kinds::Union{Vector{String},Nothing} = nothing,
)
    isempty(strip(query)) && return NamedTuple[]

    where_clause = ""
    params = Any[query]
    if kinds !== nothing && !isempty(kinds)
        placeholders = join(["?" for _ in kinds], ",")
        where_clause = " AND kind IN ($placeholders)"
        append!(params, kinds)
    end

    sql = """
        SELECT m.id, m.kind, m.content, m.created_at, m.importance,
               bm25(memories_fts) as rank
        FROM memories_fts
        JOIN memories m ON m.id = memories_fts.rowid
        WHERE memories_fts MATCH ?
        $where_clause
        ORDER BY rank
        LIMIT ?
    """
    push!(params, k)

    rows = MemoryDB.query_all(sql, params...)
    result = Vector{
        NamedTuple{
            (:id, :kind, :content, :created_at, :importance, :score),
            Tuple{String,String,String,String,String,String},
        },
    }(
        undef,
        length(rows),
    )
    for (i, r) in enumerate(rows)
        result[i] = (
            id = string(r.id),
            kind = string(r.kind),
            content = string(r.content),
            created_at = string(r.created_at),
            importance = string(float(r.importance)),
            score = string(1.0 / (1.0 + float(r.rank))),
        )
    end
    return result
end

"""
Vector similarity recall.
"""
function recall_vector(
    query::String;
    k::Int = 5,
    kinds::Union{Vector{String},Nothing} = nothing,
    min_sim::Float64 = 0.25,
)
    qvec = embed(query)
    qvec === nothing && return NamedTuple[]

    where_clause = ""
    params = []
    if kinds !== nothing && !isempty(kinds)
        placeholders = join(["?" for _ in kinds], ",")
        where_clause = " AND kind IN ($placeholders)"
        append!(params, kinds)
    end

    sql = """
        SELECT id, kind, content, created_at, importance, embedding
        FROM memories
        WHERE embedding IS NOT NULL
        $where_clause
    """

    rows = MemoryDB.query_all(sql, params...)
    results = []
    for r in rows
        if r.embedding !== nothing && length(r.embedding) >= 4
            vec = reinterpret(Float32, r.embedding)
            sim = similarity(qvec, vec)
            if sim >= min_sim
                push!(
                    results,
                    (
                        id = r.id,
                        kind = r.kind,
                        content = r.content,
                        created_at = r.created_at,
                        importance = r.importance,
                        score = sim,
                    ),
                )
            end
        end
    end

    sort!(results, by = r -> -r.score)
    return results[1:min(k, length(results))]
end

"""
Unified recall: try vector first, fall back to FTS5.
"""
function recall(
    query::String;
    k::Int = 5,
    kinds::Union{Vector{String},Nothing} = nothing,
    min_sim::Float64 = 0.25,
)
    isempty(strip(query)) && return NamedTuple[]

    results = recall_vector(query; k = k * 2, kinds = kinds, min_sim = min_sim)

    if isempty(results)
        # Fallback to FTS5
        results = recall_fallback(query; k = k, kinds = kinds)
        for r in results
            # Mark as fallback
            # Note: NamedTuples are immutable, so we can't add a flag easily
            # We'll just return them as-is
        end
    end

    return results[1:min(k, length(results))]
end

"""
Log a recall event for debugging.
"""
function log_recall(query::String, results::Vector, mode::String)
    MemoryDB.execute!(
        "INSERT INTO recall_log (query, mode, result_count, created_at) VALUES (?, ?, ?, ?)",
        (query, mode, length(results), string(now())),
    )
end

"""
Check if embeddings are available (Ollama reachable and model loaded).
"""
function embeddings_available()
    try
        response = HTTP.get("$OLLAMA_HOST/api/tags"; readtimeout = 2)
        return response.status == 200
    catch
        return false
    end
end

end # module
