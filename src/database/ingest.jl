#=
Writing to the results database: ingestion of per-job JLD2 files, per-job shard databases and
merging of shards.
=#

"Default `transform` for ingestion: store the output dictionary unchanged."
keep_output(output, params) = output

struct EncodedTrajectory
    local_index::Int
    values::Vector{Pair{String,EncodedValue}}
end

struct EncodedJob
    job_id::Int
    set_id::Union{Int,Missing}
    trajectories::Vector{EncodedTrajectory}
end

struct EncodedFile
    source::String
    status::Symbol # :new, :skipped or :failed
    jobs::Vector{EncodedJob}
    message::String
end
EncodedFile(source, status; message = "") = EncodedFile(source, status, EncodedJob[], message)

function encode_trajectory(local_index, output, params, transform, compress)
    transformed = transform(output, params)
    values = Pair{String,EncodedValue}[string(k) => encode_value(v; compress = compress) for (k, v) in pairs(transformed)]
    return EncodedTrajectory(local_index, values)
end

"Normalise the first element of a results tuple to a vector of per-trajectory outputs."
trajectory_outputs(outputs::AbstractVector) = outputs
trajectory_outputs(output) = [output]

# ----------------------------------------------------------------------------------------------
# Writer: owns the connection and all prepared statements; only ever used from a single task.
# ----------------------------------------------------------------------------------------------

mutable struct DatabaseWriter
    db::SQLite.DB
    insert_job::SQLite.Stmt
    insert_trajectory::SQLite.Stmt
    insert_scalar::SQLite.Stmt
    insert_array::SQLite.Stmt
    insert_output_key::SQLite.Stmt
    known_jobs::Set{Int}
    known_output_keys::Set{Tuple{String,String,String}}
    in_transaction::Bool
end

function DatabaseWriter(db::SQLite.DB)
    known_output_keys = Set{Tuple{String,String,String}}(
        (r.key, r.kind, r.vtype) for r in DBInterface.execute(db, "SELECT key, kind, vtype FROM output_keys"))
    return DatabaseWriter(
        db,
        DBInterface.prepare(db, "INSERT INTO jobs(job_id, set_id, n_trajectories, source, ingested_at) VALUES (?, ?, ?, ?, ?)"),
        DBInterface.prepare(db, "INSERT INTO trajectories(job_id, set_id, local_index) VALUES (?, ?, ?)"),
        DBInterface.prepare(db, "INSERT INTO scalars(key, traj_id, vtype, value) VALUES (?, ?, ?, ?)"),
        DBInterface.prepare(db, "INSERT INTO arrays(traj_id, key, header, codec, raw_nbytes, data) VALUES (?, ?, ?, ?, ?, ?)"),
        DBInterface.prepare(db, "INSERT OR IGNORE INTO output_keys(key, kind, vtype, example_header) VALUES (?, ?, ?, ?)"),
        known_job_ids(db),
        known_output_keys,
        false,
    )
end

known_job_ids(db) = Set{Int}(r.job_id for r in DBInterface.execute(db, "SELECT job_id FROM jobs"))
known_sources(db) = Set{String}(r.source for r in DBInterface.execute(db, "SELECT DISTINCT source FROM jobs WHERE source IS NOT NULL"))

function begin_transaction!(w::DatabaseWriter)
    w.in_transaction && return
    DBInterface.execute(w.db, "BEGIN")
    w.in_transaction = true
end

function commit!(w::DatabaseWriter)
    w.in_transaction || return
    DBInterface.execute(w.db, "COMMIT")
    w.in_transaction = false
end

function rollback!(w::DatabaseWriter)
    w.in_transaction || return
    DBInterface.execute(w.db, "ROLLBACK")
    w.in_transaction = false
end

function register_output_key!(w::DatabaseWriter, key, e::EncodedValue)
    vtype = e.kind === :scalar ? e.vtype : String(JSON.parse(e.header)["t"])
    id = (key, String(e.kind), vtype)
    id in w.known_output_keys && return
    DBInterface.execute(w.insert_output_key, (key, String(e.kind), vtype, e.kind === :scalar ? missing : e.header))
    push!(w.known_output_keys, id)
end

"Insert all jobs of an encoded file that are not in the database yet. Returns the number of new jobs."
function write_file!(w::DatabaseWriter, file::EncodedFile)
    begin_transaction!(w)
    n_new = 0
    timestamp = string(Dates.now())
    for job in file.jobs
        job.job_id in w.known_jobs && continue
        DBInterface.execute(w.insert_job, (job.job_id, job.set_id, length(job.trajectories), file.source, timestamp))
        for trajectory in job.trajectories
            DBInterface.execute(w.insert_trajectory, (job.job_id, job.set_id, trajectory.local_index))
            traj_id = SQLite.last_insert_rowid(w.db)
            for (key, e) in trajectory.values
                if e.kind === :scalar
                    DBInterface.execute(w.insert_scalar, (key, traj_id, e.vtype, e.value))
                else
                    DBInterface.execute(w.insert_array, (traj_id, key, e.header, e.codec, e.raw_nbytes, e.data))
                end
                register_output_key!(w, key, e)
            end
        end
        push!(w.known_jobs, job.job_id)
        n_new += 1
    end
    return n_new
end

function insert_parameter_rows!(stmt::SQLite.Stmt, id::Int, params::AbstractDict; compress = true)
    for (k, v) in params
        e = encode_parameter(v; compress = compress)
        if e.kind === :array
            DBInterface.execute(stmt, (id, string(k), "array", missing, missing, e.header, e.codec, e.data))
        else
            DBInterface.execute(stmt, (id, string(k), String(e.kind), e.vtype, e.value, missing, missing, missing))
        end
    end
end

# ----------------------------------------------------------------------------------------------
# Queue metadata
# ----------------------------------------------------------------------------------------------

struct QueueInfo
    parameters::AbstractArray
    queue::AbstractVector
    job_to_set::Dict{Int,Int}
end

"""
    initialise_from_queue!(db, queue_file; trajectories_key="trajectories", compress=true)::QueueInfo

Record the queue file in `meta` and, on first use, fill `parameter_sets` and `parameters`.
"""
function initialise_from_queue!(db::SQLite.DB, queue_file::AbstractString; trajectories_key = "trajectories", compress = true)
    parameters, queue = jldopen(f -> (f["parameters"], f["queue"]), queue_file, "r")
    checksum = bytes2hex(open(sha256, queue_file))
    previous = get_meta(db, "queue_sha256")
    if !isnothing(previous) && previous != checksum
        @warn "The queue file $queue_file differs from the one this database was created with " *
              "($(get_meta(db, "queue_file"))). Parameter sets were not updated."
    end
    set_meta_if_missing!(db, "queue_file", abspath(queue_file))
    set_meta_if_missing!(db, "queue_sha256", checksum)
    set_meta_if_missing!(db, "queue_shape", JSON.json(Int[size(parameters)...]))
    set_meta_if_missing!(db, "trajectories_key", trajectories_key)

    n_sets = sql_value(db, "SELECT COUNT(*) FROM parameter_sets")
    if n_sets == 0
        SQLite.transaction(db) do
            insert_set = DBInterface.prepare(db, "INSERT INTO parameter_sets(set_id, cart_index, total_trajectories) VALUES (?, ?, ?)")
            insert_parameter = DBInterface.prepare(db, "INSERT INTO parameters(set_id, key, kind, vtype, value, header, codec, data) VALUES (?, ?, ?, ?, ?, ?, ?, ?)")
            for (set_id, index) in enumerate(CartesianIndices(parameters))
                params = parameters[index]
                total = get(params, "total_trajectories", get(params, "total_$(trajectories_key)", missing))
                DBInterface.execute(insert_set, (set_id, JSON.json(Int[Tuple(index)...]), total))
                insert_parameter_rows!(insert_parameter, set_id, params; compress = compress)
            end
        end
    elseif n_sets != length(parameters)
        error("The database contains $n_sets parameter sets, but the queue file $queue_file has $(length(parameters)).")
    end
    return QueueInfo(parameters, queue, jobid_to_set(parameters))
end

# ----------------------------------------------------------------------------------------------
# Ingestion of JLD2 files
# ----------------------------------------------------------------------------------------------

struct IngestContext
    queue::QueueInfo
    known_jobs::Set{Int}
    known_sources::Set{String}
    job_id_source::Symbol
    trajectories_key::String
    transform::Any
    compress::Any
end

"Cheap check (without opening the file) whether a file was already ingested."
function already_ingested(ctx::IngestContext, file::SimulationFile)
    abspath(file.path) in ctx.known_sources && return true
    if ctx.job_id_source == :filename
        jobid = try
            job_id_from_filename(file)
        catch
            return false
        end
        return jobid in ctx.known_jobs
    end
    return false
end

function encode_file(ctx::IngestContext, file::SimulationFile)
    source = abspath(file.path)
    file_results = jldopen(f -> f["results"], file.path, "r")
    jobids = resolve_job_ids(file, file_results, ctx.job_id_source)
    all(in(ctx.known_jobs), jobids) && return EncodedFile(source, :skipped)
    outputs = trajectory_outputs(file_results[1])
    params = file_results[2]
    expected = [expected_trajectories(ctx.queue.queue, id; trajectories_key = ctx.trajectories_key) for id in jobids]
    jobs = EncodedJob[]
    for (jobid, job_outputs) in split_outputs(outputs, jobids, expected)
        jobid in ctx.known_jobs && continue
        set_id = get(ctx.queue.job_to_set, jobid, nothing)
        if isnothing(set_id)
            @error "Couldn't find job id $jobid (from $(file.with_extension)) in the queue - Was the correct parameters file selected?"
            continue
        end
        trajectories = [encode_trajectory(i, o, params, ctx.transform, ctx.compress) for (i, o) in enumerate(job_outputs)]
        push!(jobs, EncodedJob(jobid, set_id, trajectories))
    end
    return EncodedFile(source, :new, jobs, "")
end

function encode_file_safely(ctx::IngestContext, file::SimulationFile)
    try
        return encode_file(ctx, file)
    catch e
        return EncodedFile(abspath(file.path), :failed; message = sprint(showerror, e))
    end
end

"""
Run the ingestion pipeline: `nthreads` tasks read and encode files, the calling task writes them.
Returns the number of new jobs, skipped files and failed files.
"""
function run_ingestion!(writer::DatabaseWriter, ctx::IngestContext, files::Vector{SimulationFile};
    nthreads = Threads.nthreads(), commit_every = 100, progress = nothing)
    paths = Channel{SimulationFile}(length(files))
    foreach(f -> put!(paths, f), files)
    close(paths)
    encoded = Channel{EncodedFile}(2 * max(nthreads, 1))
    workers = map(1:max(nthreads, 1)) do _
        Threads.@spawn for file in paths
            put!(encoded, encode_file_safely(ctx, file))
        end
    end
    closer = @async try
        foreach(wait, workers)
    finally
        close(encoded)
    end
    n_new, n_skipped, n_failed, n_since_commit = 0, 0, 0, 0
    try
        for file in encoded
            if file.status === :failed
                @warn "File $(basename(file.source)) could not be read. It may be incomplete or corrupted."
                @debug "Ingestion failed due to the following error" file = file.source error = file.message
                n_failed += 1
            else
                added = file.status === :new ? write_file!(writer, file) : 0
                added == 0 && (n_skipped += 1)
                n_new += added
                n_since_commit += 1
                if n_since_commit >= commit_every
                    commit!(writer)
                    n_since_commit = 0
                end
            end
            isnothing(progress) || update(progress)
        end
        commit!(writer)
    catch
        rollback!(writer)
        close(encoded)
        rethrow()
    end
    wait(closer)
    return (; n_new, n_skipped, n_failed)
end

function report_completeness(db::SQLite.DB, verbose::Bool)
    table = completeness_table(db)
    if verbose && nrow(table) > 0
        if nrow(table) <= 50
            println(UnicodePlots.barplot(table.set_id, table.fraction; title = "Completeness of results database"))
        end
        @info "$(sum(table.n_trajectories)) of $(sum(coalesce.(table.total_trajectories, 0))) trajectories present; " *
              "$(count(table.fraction .>= 1)) of $(nrow(table)) parameter sets complete."
    end
    return table
end

"""
    create_results_database(db_path, glob_pattern, queue_file;
        job_id_source=:filename, trajectories_key="trajectories", transform=keep_output,
        compress=true, nthreads=Threads.nthreads(), commit_every=100, journal_mode="WAL", verbose=true)

Collect all per-job JLD2 output files matching `glob_pattern` into the SQLite results database
`db_path`, creating it if necessary. This mirrors [`create_results_file`](@ref), but results are
stored per trajectory and output key, so they can be queried without loading everything.

Ingestion is **idempotent**: jobs already in the database are skipped (for `job_id_source=:filename`
before their file is even opened), so re-running with the same arguments after more jobs have
finished adds only the new results. Unreadable files are reported with a warning and skipped.

**Arguments**

`job_id_source`: `:filename` to parse job ids from file names (`name-<array>-<id>.jld2` or
`name_<id>.jld2`), or `:in_dict` to read `results[2]["jobid"]`, which may be a Vector if a file
holds the results of several jobs.

`transform`: function `(output, params) -> output` applied to every trajectory's output dictionary
before storage, e.g. to truncate time series or add derived quantities. It runs on worker threads.

`compress`: `true` for zstd level 3, `false` for no compression, or an integer zstd level.

`nthreads`: number of tasks reading and encoding files. A single task writes to the database.
Start Julia with `-t N` for this to run in parallel.

`commit_every`: number of files per database transaction.

`journal_mode`: SQLite journal mode. WAL is fastest but requires the database to be on a local
(not network) file system; use `"DELETE"` otherwise.

Returns a `DataFrame` with the completeness of every parameter set (see [`completeness`](@ref)).
"""
function create_results_database(
    db_path::AbstractString,
    glob_pattern::AbstractString,
    queue_file::AbstractString;
    job_id_source::Symbol = :filename,
    trajectories_key = "trajectories",
    transform = keep_output,
    compress = true,
    nthreads::Integer = Threads.nthreads(),
    commit_every::Integer = 100,
    journal_mode = "WAL",
    verbose::Bool = true,
)
    files = glob_files(String(glob_pattern))
    db = open_database(db_path; journal_mode = journal_mode)
    try
        queue = initialise_from_queue!(db, queue_file; trajectories_key = trajectories_key, compress = compress)
        writer = DatabaseWriter(db)
        ctx = IngestContext(queue, copy(writer.known_jobs), known_sources(db), job_id_source,
            trajectories_key, transform, compress)
        pending = filter(f -> !already_ingested(ctx, f), files)
        progress = nothing
        if verbose && !isempty(pending)
            progress = ProgressBar(total = length(pending), printing_delay = 1.0)
            set_description(progress, "Ingesting files: ")
        end
        stats = run_ingestion!(writer, ctx, pending; nthreads = nthreads, commit_every = commit_every, progress = progress)
        verbose && @info "Added $(stats.n_new) jobs; skipped $(length(files) - length(pending) + stats.n_skipped) " *
                         "already ingested files; $(stats.n_failed) files could not be read."
        return report_completeness(db, verbose)
    finally
        close(db)
    end
end

# ----------------------------------------------------------------------------------------------
# Shards
# ----------------------------------------------------------------------------------------------

"""
    write_results_shard(path, results; job_ids=nothing, transform=keep_output, compress=true)

Write the results of a single cluster job to a small, self-contained SQLite *shard* at `path`,
as an alternative to saving them with `jldsave`. `results` is the usual `(outputs, params)` tuple.
Shards are later combined with [`merge_shards!`](@ref) without decoding any values.

Job ids are taken from `params["jobid"]` unless given explicitly with `job_ids`. The shard is
written to a temporary file and moved into place, so an interrupted job never leaves a partial shard.
"""
function write_results_shard(path::AbstractString, results; job_ids = nothing, transform = keep_output, compress = true)
    outputs = trajectory_outputs(results[1])
    params = results[2]
    jobids = isnothing(job_ids) ? resolve_job_ids(SimulationFile(String(path)), results, :in_dict) :
             job_ids isa Integer ? [Int(job_ids)] : collect(Int, job_ids)
    jobs = map(split_outputs(outputs, jobids, fill(nothing, length(jobids)))) do (jobid, job_outputs)
        EncodedJob(jobid, missing, [encode_trajectory(i, o, params, transform, compress) for (i, o) in enumerate(job_outputs)])
    end
    temporary = path * ".tmp"
    rm(temporary; force = true)
    db = open_database(temporary; journal_mode = "DELETE")
    try
        set_meta!(db, "shard", "true")
        writer = DatabaseWriter(db)
        write_file!(writer, EncodedFile(basename(path), :new, jobs, ""))
        insert_parameter = DBInterface.prepare(db, "INSERT INTO job_parameters(job_id, key, kind, vtype, value, header, codec, data) VALUES (?, ?, ?, ?, ?, ?, ?, ?)")
        for jobid in jobids
            insert_parameter_rows!(insert_parameter, jobid, params; compress = compress)
        end
        commit!(writer)
    finally
        close(db)
    end
    mv(temporary, path; force = true)
    return path
end

const MERGE_STATEMENTS = [
    """INSERT INTO main.trajectories(job_id, set_id, local_index)
       SELECT st.job_id, n.set_id, st.local_index
       FROM shard.trajectories st JOIN temp.merge_jobs n ON n.job_id = st.job_id
       ORDER BY st.traj_id""",
    """INSERT INTO main.scalars(key, traj_id, vtype, value)
       SELECT ss.key, mt.traj_id, ss.vtype, ss.value
       FROM shard.scalars ss
       JOIN shard.trajectories st ON st.traj_id = ss.traj_id
       JOIN temp.merge_jobs n ON n.job_id = st.job_id
       JOIN main.trajectories mt ON mt.job_id = st.job_id AND mt.local_index = st.local_index""",
    """INSERT INTO main.arrays(traj_id, key, header, codec, raw_nbytes, data)
       SELECT mt.traj_id, sa.key, sa.header, sa.codec, sa.raw_nbytes, sa.data
       FROM shard.arrays sa
       JOIN shard.trajectories st ON st.traj_id = sa.traj_id
       JOIN temp.merge_jobs n ON n.job_id = st.job_id
       JOIN main.trajectories mt ON mt.job_id = st.job_id AND mt.local_index = st.local_index""",
    "INSERT OR IGNORE INTO main.output_keys SELECT * FROM shard.output_keys",
]

function merge_shard!(db::SQLite.DB, source::String, queue::QueueInfo)
    DBInterface.execute(db, "ATTACH DATABASE ? AS shard", (source,))
    try
        version = sql_value(db, "PRAGMA shard.user_version")
        version <= SCHEMA_VERSION || error("Shard uses schema version $version.")
        new_jobs = [(r.job_id, r.n_trajectories) for r in DBInterface.execute(db,
            "SELECT job_id, n_trajectories FROM shard.jobs WHERE job_id NOT IN (SELECT job_id FROM main.jobs)")]
        isempty(new_jobs) && return 0
        n_new = 0
        SQLite.transaction(db) do
            DBInterface.execute(db, "CREATE TEMP TABLE IF NOT EXISTS merge_jobs(job_id INTEGER PRIMARY KEY, set_id INTEGER)")
            DBInterface.execute(db, "DELETE FROM temp.merge_jobs")
            timestamp = string(Dates.now())
            for (jobid, n_trajectories) in new_jobs
                set_id = get(queue.job_to_set, jobid, nothing)
                if isnothing(set_id)
                    @error "Couldn't find job id $jobid (from $(basename(source))) in the queue - Was the correct parameters file selected?"
                    continue
                end
                DBInterface.execute(db, "INSERT INTO main.jobs(job_id, set_id, n_trajectories, source, ingested_at) VALUES (?, ?, ?, ?, ?)",
                    (jobid, set_id, n_trajectories, source, timestamp))
                DBInterface.execute(db, "INSERT INTO temp.merge_jobs(job_id, set_id) VALUES (?, ?)", (jobid, set_id))
                n_new += 1
            end
            foreach(sql -> DBInterface.execute(db, sql), MERGE_STATEMENTS)
        end
        return n_new
    finally
        DBInterface.execute(db, "DETACH DATABASE shard")
    end
end

"""
    merge_shards!(db_path, glob_pattern, queue_file; trajectories_key="trajectories", journal_mode="WAL", verbose=true)

Merge all shard databases matching `glob_pattern` (written by [`write_results_shard`](@ref)) into
the results database `db_path`, creating it if necessary. Values are copied byte-for-byte with
`INSERT … SELECT`, so no packages defining the output types need to be loaded.

Like [`create_results_database`](@ref), merging is idempotent: jobs already present are skipped.
Returns a completeness `DataFrame`.
"""
function merge_shards!(
    db_path::AbstractString,
    glob_pattern::AbstractString,
    queue_file::AbstractString;
    trajectories_key = "trajectories",
    journal_mode = "WAL",
    verbose::Bool = true,
)
    files = glob_files(String(glob_pattern))
    db = open_database(db_path; journal_mode = journal_mode)
    try
        queue = initialise_from_queue!(db, queue_file; trajectories_key = trajectories_key)
        merged_sources = known_sources(db)
        pending = filter(f -> !(abspath(f.path) in merged_sources), files)
        progress = verbose && !isempty(pending) ? ProgressBar(total = length(pending), printing_delay = 1.0) : nothing
        isnothing(progress) || set_description(progress, "Merging shards: ")
        n_new, n_failed = 0, 0
        for file in pending
            try
                n_new += merge_shard!(db, abspath(file.path), queue)
            catch e
                @warn "Shard $(file.with_extension) could not be merged. It may be incomplete or corrupted."
                @debug "Merging failed due to the following error" error = e
                n_failed += 1
            end
            isnothing(progress) || update(progress)
        end
        verbose && @info "Added $n_new jobs from $(length(pending)) shards; $n_failed shards could not be merged."
        return report_completeness(db, verbose)
    finally
        close(db)
    end
end
