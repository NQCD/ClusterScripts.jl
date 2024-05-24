module ClusterScripts

# Write your package code here.
using Distributed
using DiffEqBase
using JLD2
using RobustPmap
using Glob
using ProgressBars

"""
Struct to hold file paths and provide some basic functionality for working with them.
"""
struct SimulationFile
    path::String
    stem::String
    name::String
    with_extension::String
    function SimulationFile(full_path::String; path_delim="/")
        split_path = split(full_path, path_delim)
        stem = join(split_path[1:end-1], path_delim) * path_delim
        with_extension = split_path[end]
        name = join(split(with_extension, ".")[1:end-1], ".")
        new(full_path, stem, name, with_extension)
    end
end

"""
Struct to view into results files, loading full results only if directly accessed.

If parameters or derived_quantities are modified, remember to call `save!()` to update the file.
Modifications to results outside those made by `concatenate_results!` will not be saved.
"""
struct ResultsLazyLoader
    file
    parameters::AbstractArray
    derived_quantities::AbstractArray
    function ResultsLazyLoader(file::String)
        open_file = isfile(file) ? jldopen(file, "a+", compress=true) : throw(ArgumentError("File $file does not exist."))
        new(open_file, deepcopy(open_file["parameters"]), deepcopy(open_file["derived_quantities"]))
    end
end
export ResultsLazyLoader

include("concat_output.jl")

include("pmap.jl")
export pmap_queue, merge_pmap_results

include("file_based.jl")
export build_job_queue, create_results_file, update_results_file, update_results_file!, serialise_queue!, save!

include("csv_out.jl")
export create_csv_file, update_csv_file!

end
