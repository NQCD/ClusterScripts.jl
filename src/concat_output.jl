


function concatenate_results!(
    results_container::AbstractArray,
    glob_pattern::String,
    queue_file::String;
    trajectories_key = "trajectories",
    job_id_source = :filename,
)
    # Read in all files for a simulation queue.
    all_files = glob_files(glob_pattern)
    progress = ProgressBar(total = length(all_files), printing_delay = 1.0)
    set_description(progress, "Processing files: ")
    # Import simulation parameters
    simulation_parameters = jldopen(queue_file)
    # Look up which parameter set each job belongs to.
    job_to_set = jobid_to_set(simulation_parameters["parameters"])
    for file_index in eachindex(all_files)
        try
            file_results = jldopen(f -> f["results"], all_files[file_index].path, "r")
            # Move data to the output tensor
            jobids = resolve_job_ids(all_files[file_index], file_results, job_id_source)
            parameter_index = get(job_to_set, first(jobids), nothing)
            if !isnothing(parameter_index)
                if !isassigned(results_container, parameter_index)
                    results_container[parameter_index] = file_results
                    setdiff!(results_container[parameter_index][2]["job_ids"], jobids)
                elseif any(in(results_container[parameter_index][2]["job_ids"]), jobids)
                    results_container[parameter_index] = push_nqcd_outputs!(
                        results_container[parameter_index],
                        [file_results];
                        trajectories_key = trajectories_key,
                    )
                    setdiff!(results_container[parameter_index][2]["job_ids"], jobids)
                end
            else
                @error "Couldn't find a job ID for this file - Was the correct parameters file selected?"
            end
            # Remove job id from parameters once that result has been added
        catch e
            @warn "File $(all_files[file_index].name) could not be read. It may be incomplete or corrupted."
            @debug "Concatenation logic failed due to the following error" error = e
            continue
        end
        update(progress)
    end
    # Trajectory completeness check
    parameter_sets = []
    completeness = Float64[]
    for idx in eachindex(results_container)
        push!(parameter_sets, idx)
        if isassigned(results_container, idx)
            push!(
                completeness,
                length(results_container[idx][2]["job_ids"]) /
                length(simulation_parameters["parameters"][idx]["job_ids"]),
            )
        else
            push!(completeness, 0.0)
        end
    end
    UnicodePlots.barplot(
        parameter_sets,
        completeness;
        title = "Completeness of results file",
    )
end

function concatenate_results!(
    results_container::ResultsLazyLoader,
    glob_pattern::String,
    queue_file::String;
    trajectories_key = "trajectories",
)
    # Read in all files for a simulation queue.
    all_files = glob_files(glob_pattern)
    progress = ProgressBar(total = length(all_files), printing_delay = 1.0)
    set_description(progress, "Processing files: ")
    # Import simulation parameters
    simulation_parameters = jldopen(queue_file)
    # Go through each element in the input tensor and collect all jobs we have for it.
    for index in eachindex(results_container.parameters)
        # Read job ids from results if possible to avoid reading duplicates.
        job_ids = results_container.parameters[index]["job_ids"]
        data_to_append = []
        trajectories_read = 0
        ids_read = Int[]
        to_read = findall(x -> job_id_from_filename(x) in job_ids, all_files)
        sizehint!(data_to_append, length(to_read))
        sizehint!(ids_read, length(to_read))
        for file_index in to_read
            try
                file_results = jldopen(all_files[file_index].path)["results"]
                # Put data into vector if not already
                file_data =
                    isa(file_results[1], Vector) ? file_results[1] : [file_results[1]]
                # Move to cache
                append!(data_to_append, file_data)
                # Update trajectory count
                trajectories_read += file_results[2][trajectories_key]
                # Update job ids processed
                push!(ids_read, job_id_from_filename(all_files[file_index]))
            catch e
                throw
                @warn "File $(all_files[file_index].name) could not be read. It may be incomplete or corrupted."
                @debug e
                continue
            end
            update(progress)
        end
        if length(data_to_append) > 0
            if !haskey(results_container.file["results"], "$(index)")
                results_container[index] = data_to_append
            else
                results_container[index] =
                    append!(deepcopy(results_container[index]), data_to_append)
            end
            results_container.parameters[index][trajectories_key] += trajectories_read
            setdiff!(results_container.parameters[index]["job_ids"], ids_read)
        end
        # Trajectory completeness check
        if !haskey(results_container.file["results"], "$(index)") ||
           results_container.parameters[index]["total_$(trajectories_key)"] !=
           results_container.parameters[index][trajectories_key]
            @info "Simulation results are incomplete or oversubscribed in results[$(index)]. Make sure you have run all sub-jobs. "
        end
    end
    # Save updated parameters.
    @time "Saving:" save!(results_container)
end

"""
    push_nqcd_outputs!!(first_output, other_outputs...)

Like a push!() function, but it also puts `first_output` into a vector if it wasn't already and adds the number of trajectories together.
"""
function push_nqcd_outputs!(first_output, other_outputs; trajectories_key = "trajectories")
    for i in other_outputs
        for (k, v) in i[2]
            if k == trajectories_key
                first_output[2][trajectories_key] += v
            end
        end
        if !isa(first_output[1], Vector)
            #? Can't modify first_output[1] directly due to data type of the results tuple.
            first_output = ([first_output[1]], first_output[2])
        end
        if isa(i[1], Vector)
            push!(first_output[1], i[1]...)
        else
            push!(first_output[1], i[1])
        end
    end
    return first_output
end
