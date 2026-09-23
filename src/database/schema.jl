#=
SQLite schema of the results database. See `docs/src/database.md` for a description.
=#

const SCHEMA_VERSION = 1

const SCHEMA = [
    """CREATE TABLE IF NOT EXISTS meta (
        key TEXT PRIMARY KEY,
        value TEXT
    )""",
    """CREATE TABLE IF NOT EXISTS parameter_sets (
        set_id INTEGER PRIMARY KEY,
        cart_index TEXT,
        total_trajectories INTEGER
    )""",
    """CREATE TABLE IF NOT EXISTS parameters (
        set_id INTEGER NOT NULL,
        key TEXT NOT NULL,
        kind TEXT NOT NULL,
        vtype TEXT,
        value,
        header TEXT,
        codec TEXT,
        data BLOB,
        PRIMARY KEY (set_id, key)
    )""",
    """CREATE TABLE IF NOT EXISTS jobs (
        job_id INTEGER PRIMARY KEY,
        set_id INTEGER,
        n_trajectories INTEGER NOT NULL,
        source TEXT,
        ingested_at TEXT
    )""",
    "CREATE INDEX IF NOT EXISTS jobs_source ON jobs(source)",
    # Per-job input parameters; only populated in shards written by `write_results_shard`.
    """CREATE TABLE IF NOT EXISTS job_parameters (
        job_id INTEGER NOT NULL,
        key TEXT NOT NULL,
        kind TEXT NOT NULL,
        vtype TEXT,
        value,
        header TEXT,
        codec TEXT,
        data BLOB,
        PRIMARY KEY (job_id, key)
    )""",
    """CREATE TABLE IF NOT EXISTS trajectories (
        traj_id INTEGER PRIMARY KEY,
        job_id INTEGER NOT NULL,
        set_id INTEGER,
        local_index INTEGER NOT NULL,
        UNIQUE (job_id, local_index)
    )""",
    "CREATE INDEX IF NOT EXISTS trajectories_set ON trajectories(set_id)",
    # Clustered by key so that one output across the whole ensemble is a contiguous scan.
    """CREATE TABLE IF NOT EXISTS scalars (
        key TEXT NOT NULL,
        traj_id INTEGER NOT NULL,
        vtype TEXT NOT NULL,
        value,
        PRIMARY KEY (key, traj_id)
    ) WITHOUT ROWID""",
    # `data` is the last column so scans over the header never read blob overflow pages.
    """CREATE TABLE IF NOT EXISTS arrays (
        traj_id INTEGER NOT NULL,
        key TEXT NOT NULL,
        header TEXT NOT NULL,
        codec TEXT NOT NULL,
        raw_nbytes INTEGER NOT NULL,
        data BLOB,
        PRIMARY KEY (traj_id, key)
    )""",
    "CREATE INDEX IF NOT EXISTS arrays_key ON arrays(key, traj_id)",
    # One row per (output key, storage kind, type) seen, with an example array header.
    """CREATE TABLE IF NOT EXISTS output_keys (
        key TEXT NOT NULL,
        kind TEXT NOT NULL,
        vtype TEXT NOT NULL,
        example_header TEXT,
        PRIMARY KEY (key, kind, vtype)
    ) WITHOUT ROWID""",
]

"""
    open_database(path; journal_mode="WAL", create=true)::SQLite.DB

Open (and if `create`, initialise) a results database with the ClusterScripts schema.
`journal_mode=nothing` keeps the database's current journal mode.
"""
function open_database(path::AbstractString; journal_mode = "WAL", create = true)
    !create && !isfile(path) && throw(ArgumentError("Database file $path does not exist."))
    db = SQLite.DB(path)
    sql_value(db, "PRAGMA busy_timeout = 60000")
    isnothing(journal_mode) || sql_value(db, "PRAGMA journal_mode = $journal_mode")
    sql_value(db, "PRAGMA synchronous = NORMAL")
    version = sql_value(db, "PRAGMA user_version")
    if version > SCHEMA_VERSION
        close(db)
        error("$path uses schema version $version, but this version of ClusterScripts only supports up to $SCHEMA_VERSION.")
    end
    if create
        SQLite.transaction(db) do
            foreach(sql -> DBInterface.execute(db, sql), SCHEMA)
            DBInterface.execute(db, "PRAGMA user_version = $SCHEMA_VERSION")
        end
        set_meta_if_missing!(db, "schema_version", string(SCHEMA_VERSION))
        set_meta_if_missing!(db, "codec_version", string(CODEC_VERSION))
        set_meta_if_missing!(db, "byte_order", "little")
        set_meta_if_missing!(db, "created_at", string(Dates.now()))
        set_meta!(db, "clusterscripts_version", string(pkgversion(@__MODULE__)))
        set_meta!(db, "julia_version", string(VERSION))
    end
    return db
end

set_meta!(db, key, value) =
    DBInterface.execute(db, "INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)", (key, value))
set_meta_if_missing!(db, key, value) =
    DBInterface.execute(db, "INSERT OR IGNORE INTO meta(key, value) VALUES (?, ?)", (key, value))

"""
    sql_value(db, sql, params=(); default=nothing)

First column of the first result row, or `default` if there are no rows. Also used to run
statements that return a row (e.g. PRAGMAs), since the statement is always completed. (SQLite.jl rows are
views of the live statement, so they must be read before the query advances.)
"""
function sql_value(db, sql, params = (); default = nothing)
    rows = DBInterface.execute(db, sql, params)
    try
        for row in rows
            return row[1]
        end
        return default
    finally
        DBInterface.close!(rows)
    end
end

get_meta(db, key, default = nothing) = sql_value(db, "SELECT value FROM meta WHERE key = ?", (key,); default = default)
