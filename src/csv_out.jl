using CSV, DataFrames

function create_csv_file(output_filename::String, glob_pattern::String, queue_file::String)
    # Create an empty output CSV
    output_dataframe = DataFrame(job_id=Int[], parameters_set=Int[])
    return update_csv_file!(output_filename, output_dataframe, glob_pattern, queue_file)
end

function update_csv_file!(output_filename::String, input_file::DataFrame, glob_pattern::String, queue_file::String)
    simulation_parameters = jldopen(queue_file)
    # Create an empty output CSV
    # Concatenate results
    glob_pattern = SimulationFile(glob_pattern)
    all_files = map(SimulationFile, glob(glob_pattern.with_extension, glob_pattern.stem))
    progress = ProgressBar(total=length(all_files), printing_delay=1.0)
    set_description(progress, "Processing files: ")
    for index in eachindex(vec(simulation_parameters["parameters"]))
        # Read job ids from results if possible to avoid reading duplicates.
        job_ids = convert(Vector{Int64}, simulation_parameters["parameters"][index]["job_ids"])
        to_read = findall(x -> parse(Int, split(x.name, "_")[end]) in job_ids, all_files)
        for file_index in to_read
            try
                file_results = jldopen(all_files[file_index].path)["results"]
                @debug "File read successfully"
                # Columns to write out
                output_columns = [:job_id, :parameters_set]
                for (k, v) in pairs(file_results[1][1])
                    # Only make entries for non-vector outputs. (Number, Bool, String are OK)
                    !isa(v, AbstractArray) ? push!(output_columns, k) : nothing
                end
                # Collect output values
                output_values = Any[]
                all_jobids = isa(file_results[2]["jobid"], Vector) ? file_results[2]["jobid"] : [file_results[2]["jobid"]]
                new_jobids = findall(x -> !(x in input_file.job_id), all_jobids)
                push!(output_values, all_jobids[new_jobids])
                parameter_set = fill(index, length(new_jobids))
                push!(output_values, parameter_set)
                sizehint!(output_values, length(output_columns))
                for column in output_columns[3:end] #excluding job_id and parameters_set
                    col_values = getindex.(file_results[1][new_jobids], column)
                    push!(output_values, replace(col_values, nothing => missing))
                end
                # Add to Dataframe
                input_file = vcat(input_file, DataFrame([i => j for (i, j) in zip(output_columns, output_values)]), cols=:union)
            catch e
                @warn "Error reading file: $e"
            end
            update(progress)
        end
    end
    CSV.write(output_filename, input_file)
end
