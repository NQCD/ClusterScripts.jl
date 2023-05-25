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
    traj_after=loadbalance_queue(driver, build_job_queue(test_parameters,variables))
    @test length(traj_after)==(10*11)
    for i in eachindex(traj_after)
        @test traj_after[i][2]["trajectories"]==100
    end
end
