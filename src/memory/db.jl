"""
MemoryDB — SQLite-backed durable storage for Kamila memory.
Handles schema migrations, WAL mode, and provides a thin transaction helper.
"""

module MemoryDB

using SQLite
using JSON
using Tables
using Dates
using ..Kamila
using ..KamilaLog

export ensure_open,
    reset!, schema_version, execute!, query_all, transaction, migrate!, close!, open_db

const _DB = Ref{Union{Nothing,SQLite.DB}}(nothing)
const _LOCK = ReentrantLock()

DB_PATH() =
    get(ENV, "KAMILA_DB", joinpath(homedir(), ".local", "state", "kamila", "kamila.db"))

const SCHEMA_VERSION = 3

function _ddl()
    return [
        """
        CREATE TABLE IF NOT EXISTS tasks (
            id INTEGER PRIMARY KEY,
            title TEXT NOT NULL,
            description TEXT,
            category TEXT,
            priority INTEGER,
            estimated_time INTEGER,
            due_date TEXT,
            created_date TEXT,
            completed INTEGER,
            completed_date TEXT,
            tags TEXT
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS goals (
            id INTEGER PRIMARY KEY,
            goal TEXT NOT NULL,
            category TEXT,
            priority INTEGER,
            completed INTEGER,
            progress INTEGER,
            created_date TEXT,
            completed_date TEXT
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS achievements (
            id INTEGER PRIMARY KEY,
            title TEXT NOT NULL,
            description TEXT,
            date TEXT
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS chat_messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session TEXT NOT NULL,
            role TEXT NOT NULL,
            content TEXT,
            created_at TEXT,
            idx INTEGER
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS kv (
            key TEXT PRIMARY KEY,
            value TEXT
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS migrations (
            version INTEGER PRIMARY KEY,
            applied_at TEXT
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS memories (
            id INTEGER PRIMARY KEY,
            kind TEXT NOT NULL,
            content TEXT NOT NULL,
            content_hash TEXT NOT NULL UNIQUE,
            created_at TEXT NOT NULL,
            importance REAL DEFAULT 0.5,
            embedding BLOB,
            session_id INTEGER,
            period TEXT,
            period_start TEXT,
            period_end TEXT,
            source_session_id INTEGER,
            source_turn_count INTEGER,
            retryable INTEGER DEFAULT 0
        )
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_memories_kind ON memories(kind)
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_memories_created_at ON memories(created_at)
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_memories_session_id ON memories(session_id)
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_memories_period ON memories(period)
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_memories_retryable ON memories(retryable)
        """,
        """
        CREATE TABLE IF NOT EXISTS recall_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            query TEXT NOT NULL,
            mode TEXT NOT NULL,
            result_count INTEGER NOT NULL,
            created_at TEXT NOT NULL
        )
        """,
        """
        CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(
            content,
            content='memories',
            content_rowid='id'
        )
        """,
        """
        CREATE TRIGGER IF NOT EXISTS memories_ai AFTER INSERT ON memories BEGIN
            INSERT INTO memories_fts(rowid, content) VALUES (new.id, new.content);
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS memories_ad AFTER DELETE ON memories BEGIN
            INSERT INTO memories_fts(memories_fts, rowid, content) VALUES ('delete', old.id, old.content);
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS memories_au AFTER UPDATE ON memories BEGIN
            INSERT INTO memories_fts(memories_fts, rowid, content) VALUES ('delete', old.id, old.content);
            INSERT INTO memories_fts(rowid, content) VALUES (new.id, new.content);
        END
        """,
    ]
end

function open_db(path::AbstractString)
    dir = dirname(abspath(path))
    isdir(dir) || mkpath(dir)
    db = SQLite.DB(path)
    SQLite.execute(db, "PRAGMA journal_mode=WAL")
    SQLite.execute(db, "PRAGMA foreign_keys=ON")
    # Use env var at runtime for legacy JSON path
    legacy_json = get(ENV, "KAMILA_MEMORY_FILE", Kamila.MEMORY_FILE)
    migrate!(db; legacy_json = legacy_json)
    return db
end

function ensure_open()
    lock(_LOCK) do
        if _DB[] === nothing
            _DB[] = open_db(DB_PATH())
        end
        return _DB[]
    end
end

function reset!()
    lock(_LOCK) do
        if _DB[] !== nothing
            try
                SQLite.close(_DB[])
            catch
            end
            _DB[] = nothing
        end
    end
    return nothing
end

function close!()
    reset!()
end

function schema_version(db::SQLite.DB)
    try
        rows = SQLite.DBInterface.execute(db, "PRAGMA user_version")
        return first(rows).user_version::Int
    catch
        return 0
    end
end

function _import_legacy!(db::SQLite.DB, legacy_json::AbstractString)
    isfile(legacy_json) || return
    data = nothing
    try
        data = JSON.parsefile(legacy_json)
    catch
        return
    end
    data === nothing && return

    user_alias = get(data, "user_alias", "Blue")
    SQLite.execute(
        db,
        "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
        ("user_alias", string(user_alias)),
    )

    if haskey(data, "usage_stats")
        stats = data["usage_stats"]
        if stats isa AbstractDict
            SQLite.execute(
                db,
                "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
                ("usage_stats", JSON.json(stats)),
            )
        end
    end

    if haskey(data, "last_updated")
        SQLite.execute(
            db,
            "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
            ("last_updated", string(data["last_updated"])),
        )
    end

    if haskey(data, "tasks")
        for t in data["tasks"]
            tags = get(t, "tags", String[])
            SQLite.execute(
                db,
                "INSERT OR REPLACE INTO tasks (id, title, description, category, priority, estimated_time, due_date, created_date, completed, completed_date, tags) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                (
                    get(t, "id", 0),
                    get(t, "title", ""),
                    get(t, "description", ""),
                    get(t, "category", "general"),
                    get(t, "priority", 2),
                    get(t, "estimated_time", 30),
                    get(t, "due_date", ""),
                    get(t, "created_date", ""),
                    get(t, "completed", false) ? 1 : 0,
                    get(t, "completed_date", ""),
                    JSON.json(tags),
                ),
            )
        end
    end

    if haskey(data, "goals")
        for g in data["goals"]
            SQLite.execute(
                db,
                "INSERT OR REPLACE INTO goals (id, goal, category, priority, completed, progress, created_date, completed_date) VALUES (?,?,?,?,?,?,?,?)",
                (
                    get(g, "id", 0),
                    get(g, "goal", ""),
                    get(g, "category", "general"),
                    get(g, "priority", 1),
                    get(g, "completed", false) ? 1 : 0,
                    get(g, "progress", 0),
                    get(g, "created_date", ""),
                    get(g, "completed_date", ""),
                ),
            )
        end
    end

    if haskey(data, "achievements")
        for a in data["achievements"]
            SQLite.execute(
                db,
                "INSERT OR REPLACE INTO achievements (id, title, description, date) VALUES (?,?,?,?)",
                (
                    get(a, "id", 0),
                    get(a, "title", ""),
                    get(a, "description", ""),
                    get(a, "date", ""),
                ),
            )
        end
    end
end

function migrate!(db::SQLite.DB; legacy_json::Union{String,Nothing} = nothing)
    # Always run full DDL to ensure all base tables exist (idempotent via IF NOT EXISTS)
    # This repairs corrupted DBs where migrations ran but tables are missing
    KamilaLog.debug("Running full DDL to ensure schema integrity"; mod = "memory")
    for stmt in _ddl()
        try
            SQLite.execute(db, stmt)
        catch e
            KamilaLog.warn("DDL statement failed (may already exist): $e"; mod = "memory")
        end
    end

    v = schema_version(db)
    if v < 1
        KamilaLog.info("Running database migration to schema v1"; mod = "memory")
        SQLite.execute(db, "PRAGMA user_version = 1")
        SQLite.execute(
            db,
            "INSERT OR REPLACE INTO migrations (version, applied_at) VALUES (?, ?)",
            (1, string(now())),
        )
        if legacy_json !== nothing
            _import_legacy!(db, legacy_json)
        end
    end
    if v < 2
        KamilaLog.info(
            "Running database migration to schema v2 (memories, FTS5)";
            mod = "memory",
        )
        SQLite.execute(db, "PRAGMA user_version = 2")
        SQLite.execute(
            db,
            "INSERT OR REPLACE INTO migrations (version, applied_at) VALUES (?, ?)",
            (2, string(now())),
        )
    end
    if v < 3
        KamilaLog.info(
            "Running database migration to schema v3 (episodic columns)";
            mod = "memory",
        )
        # Add new columns to memories table
        for stmt in [
            "ALTER TABLE memories ADD COLUMN session_id INTEGER",
            "ALTER TABLE memories ADD COLUMN period TEXT",
            "ALTER TABLE memories ADD COLUMN period_start TEXT",
            "ALTER TABLE memories ADD COLUMN period_end TEXT",
            "ALTER TABLE memories ADD COLUMN source_session_id INTEGER",
            "ALTER TABLE memories ADD COLUMN source_turn_count INTEGER",
            "ALTER TABLE memories ADD COLUMN retryable INTEGER DEFAULT 0",
        ]
            try
                SQLite.execute(db, stmt)
            catch e
                KamilaLog.warn(
                    "Migration v3 column add failed (may already exist): $e";
                    mod = "memory",
                )
            end
        end
        # Create new indexes
        for stmt in [
            "CREATE INDEX IF NOT EXISTS idx_memories_session_id ON memories(session_id)",
            "CREATE INDEX IF NOT EXISTS idx_memories_period ON memories(period)",
            "CREATE INDEX IF NOT EXISTS idx_memories_retryable ON memories(retryable)",
        ]
            try
                SQLite.execute(db, stmt)
            catch e
                KamilaLog.warn(
                    "Migration v3 index failed (may already exist): $e";
                    mod = "memory",
                )
            end
        end
        SQLite.execute(db, "PRAGMA user_version = 3")
        SQLite.execute(
            db,
            "INSERT OR REPLACE INTO migrations (version, applied_at) VALUES (?, ?)",
            (3, string(now())),
        )
    end
    return schema_version(db)
end

function execute!(sql::AbstractString, params...)
    db = ensure_open()
    if isempty(params)
        SQLite.execute(db, sql)
    else
        # Unwrap single Tuple/AbstractVector to avoid nested tuple binding
        p =
            length(params) == 1 && (params[1] isa Tuple || params[1] isa AbstractVector) ?
            params[1] : params
        SQLite.execute(db, sql, p)
    end
    return nothing
end

function query_all(sql::AbstractString, params...)
    db = ensure_open()
    if isempty(params)
        rows = SQLite.DBInterface.execute(db, sql)
    else
        p =
            length(params) == 1 && (params[1] isa Tuple || params[1] isa AbstractVector) ?
            params[1] : params
        rows = SQLite.DBInterface.execute(db, sql, Tuple(p))
    end
    # Materialize rows as NamedTuples to avoid forward-only iterator issues
    result = []
    for r in rows
        # Convert SQLite.Row to NamedTuple using column names
        cols = Tables.columnnames(r)
        vals = Tuple(Tables.getcolumn(r, c) for c in cols)
        push!(result, NamedTuple{Tuple(cols)}(vals))
    end
    return result
end

function transaction(f::Function)
    db = ensure_open()
    SQLite.execute(db, "BEGIN IMMEDIATE")
    try
        result = f(db)
        SQLite.execute(db, "COMMIT")
        return result
    catch e
        try
            SQLite.execute(db, "ROLLBACK")
        catch
        end
        rethrow(e)
    end
end

end # module
