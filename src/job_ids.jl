#=
Shared helpers for matching output files to jobs and parameter sets.
=#

"""
    glob_files(glob_pattern::String)::Vector{SimulationFile}

Return all files matching `glob_pattern`, where only the final path component may contain wildcards.
"""
function glob_files(glob_pattern::String)
    directory, pattern = dirname(glob_pattern), basename(glob_pattern)
    return map(SimulationFile, glob(pattern, isempty(directory) ? "." : directory))
end

"""
    job_id_from_filename(file::SimulationFile)::Int

Extract the job id from an output file name, accepting both `<name>-<array id>-<job id>.<ext>`
and `<name>_<job id>.<ext>`.
"""
function job_id_from_filename(file::SimulationFile)
    m = match(r"-\d*-(\d+)\.jld2$", file.with_extension)
    isnothing(m) && (m = match(r"_(\d+)$", file.name))
    isnothing(m) && throw(ArgumentError("Could not determine a job id from the file name $(file.with_extension)"))
    return parse(Int, only(m.captures))
end

"""
    resolve_job_ids(file::SimulationFile, file_results, job_id_source::Symbol)::Vector{Int}

Determine the job id(s) whose results are contained in `file`.

- `job_id_source = :filename` parses the file name (see [`job_id_from_filename`](@ref)).
- `job_id_source = :in_dict` reads `file_results[2]["jobid"]`, which may be a single id or a
  Vector of ids if a single process ran several jobs.
"""
function resolve_job_ids(file::SimulationFile, file_results, job_id_source::Symbol)
    if job_id_source == :filename
        return [job_id_from_filename(file)]
    elseif job_id_source == :in_dict
        jobid = file_results[2]["jobid"]
        return jobid isa AbstractVector ? convert(Vector{Int}, jobid) : [Int(jobid)]
    end
    throw(ArgumentError("Unknown job_id_source $(repr(job_id_source)); use :filename or :in_dict."))
end

"""
    jobid_to_set(parameters::AbstractArray)::Dict{Int,Int}

Map every job id in a serialised queue (the `"job_ids"` of each parameter set) to the linear
index of its parameter set.
"""
function jobid_to_set(parameters::AbstractArray)
    mapping = Dict{Int,Int}()
    for (set_id, params) in enumerate(vec(parameters))
        for jobid in get(params, "job_ids", Int[])
            mapping[Int(jobid)] = set_id
        end
    end
    return mapping
end

"""
    expected_trajectories(queue::AbstractVector, jobid::Int; trajectories_key="trajectories")

Number of trajectories job `jobid` was asked to run according to the serialised queue,
or `nothing` if unknown.
"""
function expected_trajectories(queue::AbstractVector, jobid::Int; trajectories_key = "trajectories")
    checkbounds(Bool, queue, jobid) || return nothing
    params = only(queue[jobid])
    return get(params, trajectories_key, nothing)
end

"""
    split_outputs(outputs::AbstractVector, jobids, expected_counts)

Assign the trajectories in a file to the job ids it contains. A single job receives all outputs.
Several jobs split them in order, using the queue's expected trajectory counts if they add up,
or evenly otherwise.
"""
function split_outputs(outputs::AbstractVector, jobids::AbstractVector{Int}, expected_counts)
    length(jobids) == 1 && return [only(jobids) => collect(outputs)]
    n = length(outputs)
    counts = if all(!isnothing, expected_counts) && sum(expected_counts) == n
        collect(Int, expected_counts)
    elseif n % length(jobids) == 0
        fill(n ÷ length(jobids), length(jobids))
    else
        throw(ArgumentError("Cannot split $n trajectories between the $(length(jobids)) jobs $(jobids)."))
    end
    ends = cumsum(counts)
    return [jobids[i] => outputs[(ends[i]-counts[i]+1):ends[i]] for i in eachindex(jobids)]
end
