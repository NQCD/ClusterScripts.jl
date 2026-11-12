#=
Reading from the results database.
=#

"""
    ResultsDB(path; readonly=true)
    ResultsDB(f::Function, path; readonly=true)

Open a results database created by [`create_results_database`](@ref) or [`merge_shards!`](@ref).
Close it with `close(db)`, or use the do-block form to close it automatically.

The underlying `SQLite.DB` is available as `db.conn` for raw SQL queries, e.g.
`DataFrame(DBInterface.execute(db.conn, "SELECT * FROM jobs"))`.
"""
struct ResultsDB
    path::String
    conn::SQLite.DB
end

function ResultsDB(path::AbstractString; readonly::Bool = true)
    isfile(path) || throw(ArgumentError("Database file $path does not exist."))
    conn = open_database(path; create = !readonly, journal_mode = readonly ? nothing : "WAL")
    readonly && sql_value(conn, "PRAGMA query_only = 1")
    return ResultsDB(String(path), conn)
end

function ResultsDB(f::Function, path::AbstractString; kwargs...)
    db = ResultsDB(path; kwargs...)
    try
        return f(db)
    finally
        close(db)
    end
end

Base.close(db::ResultsDB) = close(db.conn)

query(db::ResultsDB, sql, params = ()) = DBInterface.execute(db.conn, sql, params)
query_df(db::ResultsDB, sql, params = ()) = DataFrame(query(db, sql, params))
query_value(db::ResultsDB, sql, params = ()) = sql_value(db.conn, sql, params)

function Base.show(io::IO, db::ResultsDB)
    print(io, "ResultsDB(", repr(db.path), ")")
    get(io, :compact, false) && return
    try
        table = completeness(db)
        n_jobs = query_value(db, "SELECT COUNT(*) FROM jobs")
        output_keys = unique(keys(db).key)
        print(io, "\n  parameter sets: ", nrow(table), " (", count(>=(1), skipmissing(table.fraction)), " complete)")
        print(io, "\n  trajectories:   ", query_value(db, "SELECT COUNT(*) FROM trajectories"), " from ", n_jobs, " jobs")
        print(io, "\n  output keys:    ", join(output_keys, ", "))
    catch e
        print(io, " (", sprint(showerror, e), ")")
    end
end

"JSON array literal for use with `IN (SELECT value FROM json_each(?))`."
json_list(values) = JSON.json(collect(values))
as_list(x::Union{Integer,AbstractString,Symbol}) = [x]
as_list(x) = collect(x)

decode_stored(vtype, value, header, codec, data) =
    ismissing(header) ? decode_scalar(vtype, value) : decode_value(header, codec, data)

function decode_parameter(kind, vtype, value, header, codec, data)
    kind == "array" && return decode_value(header, codec, data)
    kind == "repr" && return value
    return decode_scalar(vtype, value)
end

"""
    keys(db::ResultsDB)::DataFrame

List the stored output keys with their storage kind (`scalar` or `array`), type (`vtype` for
scalars, codec node type for arrays) and, for arrays, the element type and shape of an example
value. A key can appear several times if its type differs between trajectories (e.g. `nothing`
for some trajectories and an array for others). No array data is read.
"""
function Base.keys(db::ResultsDB)
    table = query_df(db, "SELECT key, kind, vtype AS type, example_header FROM output_keys ORDER BY key, kind, type")
    headers = [ismissing(h) ? nothing : JSON.parse(h) for h in table.example_header]
    table.eltype = [isnothing(h) ? missing : get(h, "eltype", get(h, "vector_eltype", missing)) for h in headers]
    table.example_shape = [isnothing(h) || !haskey(h, "shape") ? missing : Tuple(Int.(h["shape"])) for h in headers]
    return select!(table, Not(:example_header))
end

"""
    parameters(db::ResultsDB)::DataFrame
    parameters(db::ResultsDB, set_id::Integer)::Dict{String,Any}

Input parameters of every parameter set as a wide `DataFrame` (one row per `set_id`), or of a
single set as a `Dict`. Parameters without a dedicated codec (e.g. `Unitful` quantities) are
returned as their `repr` string; the exact values are in the queue file recorded in the metadata.
"""
function parameters(db::ResultsDB, set_id::Integer)
    rows = query(db, "SELECT key, kind, vtype, value, header, codec, data FROM parameters WHERE set_id = ?", (set_id,))
    return Dict{String,Any}(r.key => decode_parameter(r.kind, r.vtype, r.value, r.header, r.codec, r.data) for r in rows)
end

function parameters(db::ResultsDB)
    table = query_df(db, "SELECT set_id, cart_index, total_trajectories FROM parameter_sets ORDER BY set_id")
    row_of = Dict(id => i for (i, id) in enumerate(table.set_id))
    columns = Dict{String,Vector{Any}}()
    for r in query(db, "SELECT set_id, key, kind, vtype, value, header, codec, data FROM parameters")
        column = get!(() -> Vector{Any}(missing, nrow(table)), columns, r.key)
        column[row_of[r.set_id]] = decode_parameter(r.kind, r.vtype, r.value, r.header, r.codec, r.data)
    end
    for key in sort!(collect(keys(columns)))
        key in names(table) && continue
        table[!, key] = map(identity, columns[key])
    end
    return table
end

"""
    completeness(db::ResultsDB)::DataFrame

Number of stored trajectories and jobs per parameter set, compared with the requested total.
"""
completeness(db::ResultsDB) = completeness_table(db.conn)

function completeness_table(conn::SQLite.DB)
    table = DataFrame(DBInterface.execute(conn, """
        SELECT p.set_id, p.cart_index, p.total_trajectories,
               COUNT(t.traj_id) AS n_trajectories, COUNT(DISTINCT t.job_id) AS n_jobs
        FROM parameter_sets p LEFT JOIN trajectories t ON t.set_id = p.set_id
        GROUP BY p.set_id ORDER BY p.set_id"""))
    table.fraction = [ismissing(total) || total == 0 ? missing : n / total
                      for (n, total) in zip(table.n_trajectories, table.total_trajectories)]
    return table
end

function trajectory_filter(; set_ids = nothing, traj_ids = nothing, alias = "t")
    clauses, params = String[], Any[]
    if !isnothing(set_ids)
        push!(clauses, "$alias.set_id IN (SELECT value FROM json_each(?))")
        push!(params, json_list(as_list(set_ids)))
    end
    if !isnothing(traj_ids)
        push!(clauses, "$alias.traj_id IN (SELECT value FROM json_each(?))")
        push!(params, json_list(as_list(traj_ids)))
    end
    return isempty(clauses) ? "" : "WHERE " * join(clauses, " AND "), params
end

"""
    scalars(db::ResultsDB; keys=nothing, set_ids=nothing)::DataFrame

All scalar outputs as a wide `DataFrame` with columns `traj_id`, `set_id`, `job_id`, `local_index`
and one column per output key. `nothing` values (and values of trajectories where the key holds an
array instead) are `missing`. By default all keys with at least one non-`nothing` scalar are included.
"""
function scalars(db::ResultsDB; keys = nothing, set_ids = nothing)
    where, params = trajectory_filter(; set_ids = set_ids)
    table = query_df(db, "SELECT traj_id, set_id, job_id, local_index FROM trajectories t $where ORDER BY traj_id", params)
    if isnothing(keys)
        keys = [r.key for r in query(db, "SELECT DISTINCT key FROM output_keys WHERE kind = 'scalar' AND vtype != 'Nothing' ORDER BY key")]
    end
    row_of = Dict(id => i for (i, id) in enumerate(table.traj_id))
    set_filter = isnothing(set_ids) ? "" : "AND traj_id IN (SELECT traj_id FROM trajectories t $where)"
    for key in string.(as_list(keys))
        column = Vector{Any}(missing, nrow(table))
        for r in query(db, "SELECT traj_id, vtype, value FROM scalars WHERE key = ? $set_filter", (key, params...))
            row = get(row_of, r.traj_id, nothing)
            isnothing(row) && continue
            value = decode_scalar(r.vtype, r.value)
            column[row] = isnothing(value) ? missing : value
        end
        table[!, key] = map(identity, column)
    end
    return table
end

"""
    ensemble_summary(db::ResultsDB, key; by=:set_id, set_ids=nothing)::DataFrame

Count, mean, standard deviation, standard error, minimum and maximum of the numeric scalar output
`key`, per parameter set (`by=:set_id`) or over all trajectories (`by=nothing`). Computed entirely
in SQL (two-pass variance), so no values are loaded into Julia. `nothing` values (and NaN, which
SQLite stores as NULL) are counted in `n_missing` and excluded from the statistics.
"""
function ensemble_summary(db::ResultsDB, key; by = :set_id, set_ids = nothing)
    group = by === :set_id ? "set_id" : isnothing(by) ? "0" :
            throw(ArgumentError("`by` must be :set_id or nothing"))
    where, params = trajectory_filter(; set_ids = set_ids)
    extra = isempty(where) ? "" : "AND " * where[7:end]
    table = query_df(db, """
        WITH v AS (
            SELECT $group AS grp, s.value AS value
            FROM scalars s JOIN trajectories t ON t.traj_id = s.traj_id
            WHERE s.key = ? AND typeof(s.value) IN ('integer', 'real', 'null') $extra
        ), m AS (
            SELECT grp, COUNT(value) AS n, COUNT(*) - COUNT(value) AS n_missing,
                   AVG(value) AS mean, MIN(value) AS minimum, MAX(value) AS maximum
            FROM v GROUP BY grp
        )
        SELECT m.grp, m.n, m.n_missing, m.mean, m.minimum, m.maximum,
               SUM((v.value - m.mean) * (v.value - m.mean)) AS sum_squares
        FROM m JOIN v ON v.grp = m.grp
        GROUP BY m.grp ORDER BY m.grp""", (string(key), params...))
    table.std = [n > 1 ? sqrt(ss / (n - 1)) : NaN for (n, ss) in zip(table.n, coalesce.(table.sum_squares, NaN))]
    table.sem = table.std ./ sqrt.(table.n)
    statistics = [:n, :n_missing, :mean, :std, :sem, :minimum, :maximum]
    return by === :set_id ? select!(rename!(table, :grp => :set_id), :set_id, statistics...) : select!(table, statistics...)
end

function decode_output_row(r)
    return (traj_id = r.traj_id, set_id = r.set_id, value = decode_stored(r.vtype, r.value, r.header, r.codec, r.data))
end

"""
    each_output(db::ResultsDB, key; set_id=nothing, traj_ids=nothing)

Lazily iterate over the values of output `key`, decoding one trajectory at a time, so outputs far
larger than memory can be processed. Yields named tuples `(traj_id, set_id, value)` in `traj_id`
order. `set_id` may be a single id or a collection of ids.
"""
function each_output(db::ResultsDB, key; set_id = nothing, traj_ids = nothing)
    where, params = trajectory_filter(; set_ids = set_id, traj_ids = traj_ids)
    rows = query(db, """
        SELECT u.traj_id, t.set_id, u.vtype, u.value, u.header, u.codec, u.data FROM (
            SELECT traj_id, vtype, value, NULL AS header, NULL AS codec, NULL AS data FROM scalars WHERE key = ?
            UNION ALL
            SELECT traj_id, NULL, NULL, header, codec, data FROM arrays WHERE key = ?
        ) u JOIN trajectories t ON t.traj_id = u.traj_id
        $where ORDER BY u.traj_id""", (string(key), string(key), params...))
    return Iterators.map(decode_output_row, rows)
end

"""
    load_output(db::ResultsDB, key; set_id=nothing, traj_ids=nothing)::Vector

Decoded values of output `key` for all (or the selected) trajectories, in `traj_id` order.
See [`each_output`](@ref) for a streaming version that also returns trajectory ids.
"""
load_output(db::ResultsDB, key; kwargs...) = map(identity, Any[r.value for r in each_output(db, key; kwargs...)])

"""
    load_trajectory(db::ResultsDB, traj_id)::Dict{Symbol,Any}

All outputs of a single trajectory.
"""
function load_trajectory(db::ResultsDB, traj_id::Integer)
    output = Dict{Symbol,Any}()
    for r in query(db, "SELECT key, vtype, value FROM scalars WHERE key IN (SELECT key FROM output_keys WHERE kind = 'scalar') AND traj_id = ?", (traj_id,))
        output[Symbol(r.key)] = decode_scalar(r.vtype, r.value)
    end
    for r in query(db, "SELECT key, header, codec, data FROM arrays WHERE traj_id = ?", (traj_id,))
        output[Symbol(r.key)] = decode_value(r.header, r.codec, r.data)
    end
    return output
end

"""
    to_results_array(db::ResultsDB; queue_file=<recorded queue file>, trajectories_key=<recorded>)

Load the whole database into the legacy format returned by [`create_results_file`](@ref): an
`Array{Tuple}` with the shape of the queue, where assigned elements hold
`(Vector{Dict{Symbol,Any}} of outputs, parameters)`. Trajectories are ordered by job id.

Parameters are read from the queue file if it is still available (exact values), otherwise from
the database. As in the legacy format, `params[trajectories_key]` holds the number of stored
trajectories and `params["job_ids"]` the ids of jobs that are still missing.
"""
function to_results_array(db::ResultsDB;
    queue_file = get_meta(db.conn, "queue_file"),
    trajectories_key = get_meta(db.conn, "trajectories_key", "trajectories"))
    shape = Tuple(Int.(JSON.parse(get_meta(db.conn, "queue_shape"))))
    queue_parameters = !isnothing(queue_file) && isfile(queue_file) ?
                       vec(jldopen(f -> f["parameters"], queue_file, "r")) : nothing
    outputs = Dict{Int,Dict{Symbol,Any}}()
    for r in query(db, "SELECT traj_id, key, vtype, value FROM scalars")
        get!(Dict{Symbol,Any}, outputs, r.traj_id)[Symbol(r.key)] = decode_scalar(r.vtype, r.value)
    end
    for r in query(db, "SELECT traj_id, key, header, codec, data FROM arrays")
        get!(Dict{Symbol,Any}, outputs, r.traj_id)[Symbol(r.key)] = decode_value(r.header, r.codec, r.data)
    end
    results = Array{Tuple}(undef, shape)
    trajectories = query_df(db, "SELECT traj_id, set_id, job_id FROM trajectories ORDER BY set_id, job_id, local_index")
    for group in groupby(trajectories, :set_id)
        set_id = first(group.set_id)
        params = isnothing(queue_parameters) ? parameters(db, set_id) : deepcopy(queue_parameters[set_id])
        params[trajectories_key] = nrow(group)
        params["job_ids"] = setdiff(get(params, "job_ids", Int[]), group.job_id)
        results[set_id] = ([get(Dict{Symbol,Any}, outputs, id) for id in group.traj_id], params)
    end
    return results
end
