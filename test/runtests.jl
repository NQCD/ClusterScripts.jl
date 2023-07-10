using ClusterScripts
using Distributed
using Test
using DiffEqBase

@testset "ClusterScripts.jl" begin
    # Write your tests here.
    test_parameters=Dict{String,Any}(
        "trajectories" => 100,
        "ensemble_algorithm" => EnsembleDistributed(),
    )
    variables=Dict{String,Any}(
        "par1" => collect(1:10),
        "par2" => collect(10:20),
    )
    addprocs(8)
    @everywhere begin
        include("../src/ClusterScripts.jl")
        function driver(x)
            return ([1],x)
        end
    end
    tq=build_job_queue(test_parameters,variables)
    serialise_queue!(tq;filename="test_queue.jld2")
    queue=jldopen("test_queue.jld2")["queue"]
    @test length(queue)==(10*11)
    total_trj=0
    for i in eachindex(queue)
        total_trj+queue[i]["trajectories"]
    end
    @test total_trj==length(queue)
end
