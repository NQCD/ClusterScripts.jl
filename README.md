# ClusterScripts

[![Build Status](https://github.com/alexsp32/ClusterScripts.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/alexsp32/ClusterScripts.jl/actions/workflows/CI.yml?query=branch%3Amain)

This package contains functions to more efficiently distribute resources to MD simulations with `NQCDynamics.jl` on HPC clusters, including the ability to initialise simulations with all possible combinations of multiple variables. This can be useful to compare results across a range of initial parameters, or with a range of different models. 


While NQCDynamics.jl provides the tools necessary to run ensemble simulations, and a means of parallelisation through SciML’s EnsembleAlgorithms, compatibility of different models with certain EnsembleAlgorithms isn’t guaranteed, nor will there necessarily be a notable gain in performance. ClusterScripts takes a different approach to parallelisation, instead running multiple instances of NQCD in parallel, allowing for more trajectories to be run simultaneously, which is advantageous for models not taking full advantage of multithreading. 

To maximise compatibility with (almost) any simulation workflow, it is up to you as a user to implement the necessary functions acting on the jobs dispatched by ClusterScripts. 

## The ClusterScripts simulation workflow
All the information necessary to run a simulation is contained in Dictionaries. 
`fixed_parameters` contains all keys common to every simulation. 
`variables` should contain variable keys with the desired vector of values. 

`build_job_queue(fixed_parameters,variables)` will generate all possible combinations of variables, building an `Array{Dict}` of all combinations of input parameters. 

`pmap_queue(target_function, params::Vector{Dict})` executes the all simulations for a set of parameters and uses **Julia's built in Multitasking/Multiprocessing functions** to split simulations into subtasks according to the desired mode of parallelisation. 
If we specify a large number of trajectories for a model best suited to single-process single-thread operation, they will be split into smaller “jobs” which are dispatched to each process for maximum use of available computing power. 

In cases where models use multithreading properly, “jobs” are still split across the total number of processes, but continue to use multithreading. 

`target_function` will be run for each combination of `params` and the results will be automatically merged back into the same shape as the `Vector{Dict}` initially input, as if we had run all trajectories within a single script. 


`serialise_queue!(input_dict_tensor::Vector{<: Dict{<: Any}}; trajectories_key="trajectories", filename="simulation_parameters.jld2")` will split the simulation queue provided into batches of a given size, which can be separately executed in parallel, e.g. using GNU parallel for trivial taskfarming. Each sub-job will create a temporary output file, which will need to be merged. 

`merge_file_results(output_filename::String, glob_pattern::String, queue_file::String;trajectories_key="trajectories")` will combine output files from sub-jobs of a larger simulation task (e.g. those created by `serialise_queue!`) back into a single output file containing an `Array` with variable dimensions, combining batches with the same parameters back together. 


## What does my simulation function need to do?
- Initialise an NQCD Model, Simulation and initial conditions from parameters contained in a single input `Dict`. 
- Return the results of the `NQCDynamics.run_dynamics()` command and the `Dict` of input values, in case anything was modified. 

> [!example] Example simulation function
> ```julia
> function langevin_dynamics(params::Dict{String,Any})
>     ase_io=pyimport("ase.io")
>     ase=pyimport("ase")
>     ase_structure=ase_io.read(params["starting_structure"]) 
>     set_calculator(ase_structure, params) # Choose the desired ML model type and attach its calculator to ase_structure
>     nqcd_model=AdiabaticASEModel(ase_structure) # Connect ase_structure calculator to NQCD
>     # Initialise NCQD Simulation
>     nqcd_atoms,positions,nqcd_cell=NQCDynamics.convert_from_ase_atoms(ase_structure)
>     simulation=Simulation{Langevin}(
>         nqcd_atoms, 
>         nqcd_model, 
>         temperature=get!(params, "temperature", 300u"K"),
>         γ=get!(params, "gamma", 0.5),
>         cell=nqcd_cell
>     )
>     # Starting conditions: initial positions and zero velocity
>     u=DynamicsVariables(simulation, zeros(size(simulation)), positions)
>     # Now run dynamics
>     traj=run_dynamics(
>         simulation,
>         (0.0u"fs", get!(params, "runtime", 0.3u"ps")),
>         u;
>         dt=get!(params, "timestep", 0.1u"fs"),
>         trajectories=get!(params, "trajectories", 1),
>         saveat=params[“saveat”], 
>         output=(OutputDynamicsVariables, OutputPotentialEnergy), # Positions, velocities and 
>         ensemble_algorithm=get!(params, "ensemble_algorithm", EnsembleSerial())
>     )
>     # Pack single trajectory into Array to ensure similarity with >1 trajectory
>     if params["trajectories"]==1
>         results=[traj]
>     else
>         results=traj
>     end
>     # Hand over an ase object for the initial structure and a simulation object for further evaluation
>     params["nqcd_simulation"]=simulation
>     params["ase_object"]=ase_structure
>     return (results, params)
> end
> ```

## Tutorial: Using ClusterScripts to speed up statistical sampling

