# Results database (SQLite)

[`create_results_file`](@ref) loads every per-job output file into memory and writes one large
JLD2 file. For large queues this has a few drawbacks:

- The whole results file (easily 100 GB+) has to be loaded before any of it can be used.
- Outputs of mixed type (scalars, arrays, vectors of arrays, `nothing`) have to be reassembled by hand.
- Building the file runs in a single process.

As an alternative, ClusterScripts can collect results into a single-file
[SQLite](https://sqlite.org) database (no server needed). In it:

- Every trajectory's outputs are stored individually, one row per output key.
- Scalar outputs are native SQL values, so ensemble statistics are cheap queries that never touch array data.
- Arrays describe themselves and decode to the original Julia structure, without you having to specify shapes or types.
- Ingestion is threaded and idempotent: running it again only adds new results.

```julia
using ClusterScripts, NQCDynamics  # load the packages defining your output types

create_results_database("results.sqlite", "output/trj_*.jld2", "simulation_parameters.jld2";
    job_id_source = :in_dict)

ResultsDB("results.sqlite") do db
    ensemble_summary(db, :OutputDesorptionAngle)   # count/mean/std/sem/min/max per parameter set
end
```

## Workflows

### A: Collect existing JLD2 output files

[`create_results_database`](@ref) takes the same arguments as [`create_results_file`](@ref).
Start Julia with several threads (`julia -t 8`). Worker tasks then read and encode the files in
parallel while a single task writes to the database.

```julia
function postprocess(output, params)
    output = copy(output)
    output[:Time] = output[:Time][end]  # only keep the final time
    return output
end

create_results_database("results.sqlite", "output/trj_*.jld2", "simulation_parameters.jld2";
    job_id_source = :in_dict, transform = postprocess)
```

- **Re-running is the "update" path.** Jobs already in the database are skipped. With
  `job_id_source = :filename` they are skipped before their file is even opened, and files that
  were already ingested are recognised by path.
- **Unreadable files** are reported with a warning and skipped, as before.
- **`transform(output, params)`** runs on every trajectory before it is stored. Use it to trim
  outputs or to add derived quantities. It runs on worker threads, so it must be thread-safe.
- **Output types must be loadable.** The packages defining your output types (e.g. NQCDynamics,
  whose outputs are `Dictionaries.Dictionary`) must be loaded, just as for reading the JLD2 files directly.

### B: Shards as job output

Instead of `jldsave`, the driver script of each cluster job can write its results to a small
SQLite *shard*:

```julia
results = run_simulation(params)             # (outputs, params) with params["jobid"] set
write_results_shard("output/trj_$(params["jobid"]).sqlite", results)
```

The shards are then combined with:

```julia
merge_shards!("results.sqlite", "output/trj_*.sqlite", "simulation_parameters.jld2")
```

Merging uses `ATTACH` + `INSERT … SELECT` and copies the encoded bytes unchanged. It needs no
decoding or re-encoding, and none of the packages defining the output types have to be loaded.
Each shard is written to a temporary file and moved into place when complete, so interrupted jobs
never leave half-written shards. Merging is idempotent, just like ingestion.

On the example data (9 NQCDynamics trajectories of ~2.9 MB JLD2 each, 4 threads, warm), merging
9 shards took 0.06 s, compared with 0.09 s for threaded JLD2 ingestion (0.19 s single-threaded).
Each shard carries about 70 KB of fixed overhead (schema pages plus the job's parameters): here
274 KB per shard against about 200 KB per trajectory in the merged database. Shards are
worthwhile when merge speed, or merging without the simulation packages, matters. JLD2 output
files remain fully supported.

### Where to put the database on HPC systems

SQLite has a single writer and relies on file locking, which is unreliable on network file systems
(NFS, Lustre, GPFS). WAL mode, the default here, additionally requires all connections to be on
the same machine.

- Build and merge the database on node-local or other non-network storage where possible (e.g.
  `$TMPDIR`), then copy the finished file. Once closed it is a single, self-contained file.
- If the database has to live on a network file system, use `journal_mode = "DELETE"` and make sure
  only one process writes to it at a time.
- **Never let running jobs write to a shared database.** Have them write JLD2 files or shards, and
  collect those afterwards.

## Schema

| table | columns | notes |
|---|---|---|
| `meta` | `key`, `value` | schema/codec version, package and Julia version, queue file path, SHA-256 and shape (JSON), trajectories key, creation time |
| `parameter_sets` | `set_id` (linear index into the queue), `cart_index` (JSON), `total_trajectories` | |
| `parameters` | `set_id`, `key`, `kind`, `vtype`, `value`, `header`, `codec`, `data` | same encoding as outputs; `kind = 'repr'` for values without a codec (e.g. `Unitful` quantities) |
| `jobs` | `job_id`, `set_id`, `n_trajectories`, `source`, `ingested_at` | makes ingestion idempotent |
| `trajectories` | `traj_id`, `job_id`, `set_id`, `local_index` | `UNIQUE(job_id, local_index)` |
| `scalars` | `key`, `traj_id`, `vtype`, `value` | `WITHOUT ROWID`, clustered by key: one output across the ensemble is one contiguous scan; `nothing` is NULL with `vtype = 'Nothing'` |
| `arrays` | `traj_id`, `key`, `header` (JSON), `codec`, `raw_nbytes`, `data` | blobs are kept apart from scalars; `data` is the last column so header scans skip the blob pages |
| `output_keys` | `key`, `kind`, `vtype`, `example_header` | every (key, kind, type) combination seen; used by `keys(db)` |
| `job_parameters` | as `parameters`, keyed by `job_id` | only filled in shards |

The completeness of a parameter set is `COUNT(trajectories)` compared with `total_trajectories`; see
[`completeness`](@ref). Parameter values stored as `repr` are only for filtering and display.
The exact, type-faithful parameters remain in the queue file, whose path and hash are recorded in
`meta` (and are used by [`to_results_array`](@ref)).

## Value encoding

- **Scalars** (`Bool`, `Int8`–`Int64`, `UInt8`–`UInt64`, `Float16`–`Float64`, `String`, `Symbol`,
  `Char`, `nothing`, `missing`) are stored as SQL `INTEGER`/`REAL`/`TEXT`/`NULL`. A `vtype` column
  records the exact Julia type.
- **NaN** is stored by SQLite as NULL. It is restored as `NaN` of the recorded float type, but SQL
  aggregates treat it as missing.

Everything else is stored as a **JSON structure header** plus a **byte payload**:

- The payload concatenates the raw, column-major, little-endian bytes of all leaves.
- It is compressed with zstd (level 3 by default, `codec = 'zstd'`) when that saves space, and
  stored as-is otherwise (`codec = 'none'`).
- Header node offsets refer to the *uncompressed* payload.
- The root node carries the codec version `"v"`.

| node `t` | used for | fields |
|---|---|---|
| `dense` | isbits arrays (`Float16/32/64`, `Int8`–`64`, `UInt8`–`64`, `Bool`, `ComplexF32/64`), including 0-d and empty arrays | `eltype`, `shape`, `offset`, `nbytes`; optional `as` (container element type, e.g. `Any`), `scalar` |
| `categorical` | `Array{Symbol}`, `Array{String}` | `eltype`, `levels`, `codes` (dense `UInt8/16/32` child, 1-based) |
| `stacked` | `Vector` of equal-shape dense arrays (e.g. trajectory frames) | `eltype`, `inner_shape`, `n`, `vector_eltype`, `offset`, `nbytes` |
| `list` | ragged or heterogeneous vectors, e.g. `Vector{Vector{Symbol}}` | `vector_eltype`, `items` |
| `arraypartition`, `tuple`, `namedtuple`, `dict` | containers | `items` (plus `names`, or `keys`/`values`/`keytype`/`valtype`) |
| `scalar`, `nothing`, `missing` | scalars inside containers | `vtype`, `v` (as a string) |
| `serialized` | anything else (last resort, with a warning) | `jl_type`, `offset`, `nbytes` |

`serialized` values use the `Serialization` stdlib. They can only be read with a compatible Julia
version, with the defining packages loaded, and only from files you trust.

New types can be supported by adding methods to `ClusterScripts.encode_node(x, ctx)`, together
with a `ClusterScripts.decode_node(::Val{:tag}, node, buffer)` method for their tag.

### Reading blobs without Julia

Python and numpy can read dense arrays without Julia:

```python
import sqlite3, json, numpy as np, zstandard
con = sqlite3.connect("results.sqlite")
header, codec, data = con.execute(
    "SELECT header, codec, data FROM arrays WHERE key = 'OutputSubsetKineticEnergy' LIMIT 1").fetchone()
node = json.loads(header)
raw = zstandard.decompress(data) if codec == "zstd" else data
dtype = {"Float64": "<f8", "Float32": "<f4", "Int64": "<i8", "Bool": "?"}[node["eltype"]]
leaf = np.frombuffer(raw, dtype=dtype, count=node["nbytes"] // np.dtype(dtype).itemsize, offset=node["offset"])
array = leaf.reshape(node["shape"], order="F")
```

Headers can also be queried directly in SQL, e.g.
`SELECT key, json_extract(header, '$.shape') FROM arrays LIMIT 10`.

## Query cookbook

```julia
db = ResultsDB("results.sqlite")    # read-only by default
db                                  # summary: parameter sets, trajectories, output keys
keys(db)                            # output keys with kind/type/example shape (no blobs read)
completeness(db)                    # stored vs. requested trajectories per parameter set

params = parameters(db)             # one row per parameter set
parameters(db, 3)                   # Dict for parameter set 3

# Ensemble statistics, computed in SQL
ensemble_summary(db, :OutputDesorptionAngle)             # per parameter set
ensemble_summary(db, :OutputDesorptionAngle; by = nothing)

# All scalar outputs as a DataFrame, joined with parameters for filtering
df = innerjoin(scalars(db), select(params, :set_id, :temperature); on = :set_id)
subset(df, :temperature => t -> t .> 300)

# Arrays
load_output(db, :OutputFinal; set_id = 2)          # Vector of decoded values
for (; traj_id, set_id, value) in each_output(db, :OutputSubsetKineticEnergy)
    # one trajectory in memory at a time
end
load_trajectory(db, 42)                             # Dict{Symbol,Any} of all outputs

# Legacy Array{Tuple} format for existing analysis scripts
results = to_results_array(db)

# Raw SQL
using DBInterface
DataFrame(DBInterface.execute(db.conn, "SELECT set_id, COUNT(*) FROM jobs GROUP BY set_id"))

close(db)
```
