# ClusterScripts.jl

!!! warning

    This documentation is a work in progress. To find out what everything in the package does, the [ClusterScripts.jl API](@ref) docstrings are currently your best bet.


This package contains functions to more efficiently distribute resources to MD simulations with `NQCDynamics.jl` on HPC clusters, including the ability to initialise simulations with all possible combinations of multiple variables.
This can be useful to compare results across a range of initial parameters, or with a range of different models.

While NQCDynamics.jl provides the tools necessary to run ensemble simulations, and a means of parallelisation through SciML’s EnsembleAlgorithms, compatibility of different models with certain EnsembleAlgorithms isn’t guaranteed, nor will there necessarily be a notable gain in performance.

Since many machine learning interatomic potentials are developed in Python, where the global interpreter lock prevents multithreading, thread parallelism provided by EnsembleAlgorithms tends not to work at all.

This leaves trivial taskfarming as the most viable option to parallelise the execution of multiple simulations across multiple HPC nodes.

This package allows for the creation and aggregation of results for [Single Instruction, multiple data (SIMD)](https://en.wikipedia.org/wiki/Single_instruction,_multiple_data) workflows on HPC clusters.

## How to build an SIMD workflow

% diagram: input: Dict of parameters -> driver function -> output Tuple of parameters and results

## Parameter grid searches

`ClusterScripts.jl` contains functions to generate a "queue" of simulation parameters containing all possible combinations of multiple variables in a simulation.
This allows for grid searches over multiple parameters, which could be used to compare e.g. different interatomic potentials over a range of different temperatures.

% diagram for Dict structure

% code example

% note that handling of all these parameters needs to be built in your own code.

## Parallel workload distribution (file-based)

% explain how jobs are created from a queue
% explain how batching can be used to split into different size chunks
% example for how to run these jobs on a cluster.

## Aggregating results

% explain how to aggregate file-based results back into a single file.
% explain how the LazyLoader saves memory and load time.

For large queues, results can also be collected into a queryable SQLite database, see [Results database (SQLite)](@ref).
