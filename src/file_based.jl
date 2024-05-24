


"""
    save!(loader::ResultsLazyLoader)

**Warning: Don't run this on an unstable system or network connection to prevent data loss!**

Updates the stored parameters and derived quantities inside a grouped JLD2 file.

Run this function after modifying `loader.parameters` or `loader.derived_quantities` to save the changes.
"""
function save!(loader::ResultsLazyLoader)
    if any(loader.parameters .!= loader.file["parameters"])
        old_parameters = deepcopy(loader.file["parameters"])
        try
            delete!(loader.file, "parameters")
            loader.file["parameters"] = loader.parameters
        catch
            loader.file["parameters"] = old_parameters
            throw
        end
    end
    if any(loader.derived_quantities .!= loader.file["derived_quantities"])
        old_derived_quantities = deepcopy(loader.file["derived_quantities"])
        try
            delete!(loader.file, "derived_quantities")
            loader.file["derived_quantities"] = loader.derived_quantities
        catch
            loader.file["derived_quantities"] = old_derived_quantities
            throw
        end
    end
    @info "Saved updated data to $(loader.file.path)"
end

Base.show(io::IO, loader::ResultsLazyLoader) = print(io, "ResultsLazyLoader($(loader.file))")
Base.size(loader::ResultsLazyLoader) = size(loader.parameters)
Base.length(loader::ResultsLazyLoader) = length(loader.parameters)
function Base.getindex(loader::ResultsLazyLoader, i::Int)
    return loader.file["results/$(i[1])"]
end
function Base.getindex(loader::ResultsLazyLoader, i::AbstractUnitRange{<:Integer})
    return [loader.file["results/$(j)"] for j in i]
end
"""
    Base.setindex!(loader::ResultsLazyLoader, val, i::Int)

**Warning: This overwrites the entire results group!**
use `loader[i]=append!(deepcopy(loader[i]), X)` or similar to append to existing data.
"""
function Base.setindex!(loader::ResultsLazyLoader, val, i::Int)
    if haskey(loader.file["results"], "$(i)")
        cache = deepcopy(loader.file["results/$(i)"])
        try
            delete!(loader.file, "results/$(i)")
            loader.file["results/$(i)"] = val
        catch
            loader.file["results/$(i)"] = cache
            throw
        end
    else
        loader.file["results/$(i)"] = val
    end
end

function save_as_jld2(filename, results_data)
    jldsave(filename, compress=true; results=results_data)
end

"""
    convert_to_grouped_jld2(filename, results_data)

Converts the results format of an ungrouped JLD2 file to the grouped format.
**Warning: This method yields undefined simulation parameters which normally shouldn't occur in grouped JLD2 files.**
"""
function convert_to_grouped_jld2(filename, results_data)
    jldopen(filename, "w"; compress=true) do file
        # Flag file as grouped
        file["grouped"] = true
        # Need to modify out-of place.
        parameters = Array{Dict{String,Any}}(undef, size(results_data))
        # Store results in separate groups to load as required
        indices_to_write = findall(x -> isassigned(results_data, x), eachindex(results_data))
        for i in ProgressBar(indices_to_write)
            parameters[i] = results_data[i][2]
            file["results/$i"] = results_data[i][1]
        end
        # Create a group to store derived quantities
        file["parameters"] = parameters
        file["derived_quantities"] = [Dict{Symbol,Any}() for i in eachindex(file["parameters"])]
    end
end

"""
    convert_to_grouped_jld2(filename, results_data, simulation_queue; trajectories_key = "trajectories")

Converts the results format of an ungrouped JLD2 file to the grouped format and adds the simulation parameters from a simulation queue.
"""
function convert_to_grouped_jld2(filename, results_data, simulation_queue; trajectories_key="trajectories")
    simulation_parameters = jldopen(simulation_queue, "r")["parameters"]
    jldopen(filename, "w"; compress=true) do file
        # Flag file as grouped
        file["grouped"] = true
        # Can't in-place modify arrays with JLD2, so need to modify out-of place.
        parameters = Array{Dict{String,Any}}(undef, size(results_data))
        # Store results in separate groups to load as required
        indices_to_write = findall(x -> isassigned(results_data, x), eachindex(results_data))
        for i in ProgressBar(indices_to_write)
            parameters[i] = results_data[i][2]
            file["results/$i"] = results_data[i][1]
        end
        for idx in symdiff(indices_to_write, eachindex(parameters))
            @info "Writing 0 trajectories for undefined result $(idx)"
            parameters[idx] = simulation_parameters[idx]
            parameters[idx][trajectories_key] = 0
            @info parameters[idx]
        end
        # Create a group to store derived quantities
        file["parameters"] = parameters
        file["derived_quantities"] = [Dict{Symbol,Any}() for i in eachindex(file["parameters"])]
    end
end

"""
    create_results_file(output_filename::String, glob_pattern::String, queue_file::String;trajectories_key="trajectories", truncate_times=true)

Compresses all results from a simulation queue back into a single file. Any missing outputs are reported as warnings and will be undefined in the final output.

This file contains the results of all jobs in the queue, as well as the input parameters for each job in the following format:

- `file["results"]` contains an Array with the same dimensions as the input parameters.
- Each element of `file["results"]` contains a tuple of the output from the simulation and the input parameters for that simulation.
- Simulation output will always be a vector, even for single trajectories, to allow for consistent analysis functions that are independent of trajectory numbers.


**Arguments**
`output_filename::String`: The name of the file to save the results to.

`glob_pattern::String`: A glob pattern to match all files to merge.

`queue_file::String`: The file containing the input parameters for the simulation queue.

`trajectories_key::String`: The key in the input parameters dictionary which describes batching behaviour. (typically "trajectories", since we want to farm out trajectories to workers)

`truncate_times::Bool`: If true, the time array in the output will be truncated to the final value only. Useful to save space when a large number of identical trajectories are run with short time steps.
"""
function create_results_file(output_filename::String, glob_pattern::String, queue_file::String; trajectories_key="trajectories", file_format::String="jld2")
    simulation_parameters = jldopen(queue_file)
    # Create an empty total output object
    output_tensor = Array{Tuple}(undef, (size(simulation_parameters["parameters"])))
    concatenate_results!(output_tensor, glob_pattern, queue_file; trajectories_key=trajectories_key)
    if file_format == "jld2"
        save_as_jld2(output_filename, reshape(output_tensor, size(simulation_parameters["parameters"])))
    elseif file_format == "jld2_grouped"
        convert_to_grouped_jld2(output_filename, reshape(output_tensor, size(simulation_parameters["parameters"])), queue_file; trajectories_key=trajectories_key)
    end
    return reshape(output_tensor, size(simulation_parameters["parameters"]))
end

"""
    update_results_file(input_file::String, glob_pattern::String, queue_file::String, output_file::String; trajectories_key="trajectories", file_format::String="jld2")

Merges existing results from an **ungrouped JLD2 file** into a new **ungrouped JLD2 file**.

**Arguments**
`output_filename::String`: The name of the file to save the results to.

`glob_pattern::String`: A glob pattern to match all files to merge.

`queue_file::String`: The file containing the input parameters for the simulation queue.

`trajectories_key::String`: The key in the input parameters dictionary which describes batching behaviour. (typically "trajectories", since we want to farm out trajectories to workers)


"""
function update_results_file(input_file::String, glob_pattern::String, queue_file::String, output_file::String; trajectories_key="trajectories", file_format::String="jld2")
    simulation_parameters = jldopen(queue_file)
    # Create an empty total output object
    output_tensor = jldopen(input_file)["results"]
    concatenate_results!(output_tensor, glob_pattern, queue_file; trajectories_key=trajectories_key)
    if file_format == "jld2"
        save_as_jld2(output_filename, output_tensor)
    end
    return reshape(output_tensor, size(simulation_parameters["parameters"]))
end

function update_results_file!(input_file::ResultsLazyLoader, glob_pattern::String, queue_file::String; trajectories_key="trajectories", file_format::String="jld2")
    concatenate_results!(input_file, glob_pattern, queue_file; trajectories_key=trajectories_key)
end

"""
    build_job_queue(fixed_parameters::Dict, variables::Dict)

Returns a Vector of all unique combinations of values in `variables` merged with `fixed_parameters`.
Each key in `variables` should be a list of possible values for that parameter. (Trivially, a length 1 list)
"""
function build_job_queue(fixed_parameters::Dict, variables::Dict)
    merged_combinations = Vector{Dict}()
    variable_combinations = reshape(collect(Iterators.product(values(variables)...)), :)
    for i in eachindex(variable_combinations)
        push!(merged_combinations, merge(fixed_parameters, Dict([(collect(keys(variables))[j], variable_combinations[i][j]) for j in 1:length(keys(variables))])))
    end
    return merged_combinations
end

"""
    build_job_queue(fixed_parameters::Dict, variables::Dict, postprocessing_function::Function)

Returns a Vector of all unique combinations of values in `variables` merged with `fixed_parameters`.
By specifying a `postprocessing_function`, further actions can be performed each of the elements in the resulting vector.
"""
function build_job_queue(fixed_parameters::Dict, variables::Dict, postprocessing_function::Function)
    merged_combinations = Vector{Dict}()
    variable_combinations = reshape(collect(Iterators.product(values(variables)...)), :)
    for i in eachindex(variable_combinations)
        push!(merged_combinations, merge(fixed_parameters, Dict([(collect(keys(variables))[j], variable_combinations[i][j]) for j in 1:length(keys(variables))])))
    end
    # Accept a function that does in-place modification of the input parameters dictionary
    return map(postprocessing_function, merged_combinations)
end

"""
    serialise_queue!(input_dict_tensor::Vector{<: Dict{<: Any}}; trajectories_key="trajectories", filename="simulation_parameters.jld2")

Performs batching on the Array of input parameters for multithreading/multiprocessing.
By assigning the key "batchsize" in the input parameters, each simulation job will be split into as many batches as necessary to run the required number of trajectories.
The default batch size is 1, i.e. trivial taskfarming.

Set "trajectories_key" in case jobs should be split by something different.

Set "filename" to save the resulting batch queue somewhere different than `simulation_parameters.jld2`.
"""
function serialise_queue!(input_dict_tensor::Vector{<:Dict{<:Any}}; trajectories_key="trajectories", filename="simulation_parameters.jld2")
    queue = [] #Empty queue array to fill with views of input_dict_tensor
    job_id = 1
    for index in eachindex(input_dict_tensor)
        # Save a list of jobs created from an input dict within it.
        input_dict_tensor[index]["job_ids"] = []
        # Save the total number of trajectories before modification of the input dict to verify completeness on analysis.
        input_dict_tensor[index]["total_trajectories"] = input_dict_tensor[index][trajectories_key]
        if get!(input_dict_tensor[index], "batchsize", 1) == 1
            # Case 1: Fully serialised operation - Split into as many jobs as trajectories.
            for trj in 1:input_dict_tensor[index][trajectories_key]
                # Add a view of the input dict
                push!(queue, view(input_dict_tensor, index))
                push!(input_dict_tensor[index]["job_ids"], job_id)
                job_id += 1
            end
            input_dict_tensor[index][trajectories_key] = 1
        else
            # Case 2: Larger batch size - There might be some benefit like multithreading, so split into chunks of a certain size.
            # Work in batchsize chunks
            input_dict_tensor[index][trajectories_key] = input_dict_tensor[index]["batchsize"]
            # If there enough trajectories to fit in >1 batch:
            for batch in 2:(floor(input_dict_tensor[index]["total_trajectories"] / input_dict_tensor[index]["batchsize"]))
                push!(queue, view(input_dict_tensor, index))
                push!(input_dict_tensor[index]["job_ids"], job_id)
                job_id += 1
            end
            extra_parameters = copy(input_dict_tensor[index])
            extra_parameters[trajectories_key] += input_dict_tensor[index]["total_trajectories"] % input_dict_tensor[index]["batchsize"]
            push!(queue, hcat(extra_parameters)) # This covers any cases where the number of trajectories isn't exactly divisible by the batch size.
            push!(input_dict_tensor[index]["job_ids"], job_id)
            job_id += 1
        end
    end
    jldsave(filename; parameters=input_dict_tensor, queue=queue)
end
