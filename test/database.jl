using ClusterScripts
using Test
using JLD2
using DataFrames
using RecursiveArrayTools
using Logging
import DBInterface

const CS = ClusterScripts

query_count(db, table) = CS.sql_value(db.conn, "SELECT COUNT(*) FROM $table")

struct UnregisteredType
    a::Int
    b::Vector{Float64}
end
Base.:(==)(x::UnregisteredType, y::UnregisteredType) = x.a == y.a && x.b == y.b

function make_queue(dir; trajectories = 4, batchsize = 1)
    fixed = Dict{String,Any}("trajectories" => trajectories, "batchsize" => batchsize, "label" => :fixed)
    variables = Dict{String,Any}("temperature" => [100.0, 200.0], "model" => ["a", "b", "c"])
    queue_file = joinpath(dir, "queue.jld2")
    serialise_queue!(build_job_queue(fixed, variables); filename = queue_file)
    return queue_file
end

function fake_output(jobid, i, temperature)
    return Dict{Symbol,Any}(
        :id => 1000 * jobid + i,
        :energy => temperature + jobid + 0.5i,
        :flag => isodd(jobid),
        :maybe => iseven(jobid) ? nothing : Float64(jobid),
        :Time => collect(0.0:0.1:1.0),
        :frames => [fill(Float64(jobid + k), 2, 3) for k in 1:(1+jobid%3)],
        :sites => [fill(:top, 1 + jobid % 2), [:hollow, :bridge]],
        :state => ArrayPartition(fill(1.0 * jobid, 2, 2), fill(-1.0 * i, 2, 2)),
    )
end

"Write one `trj_<jobid>.jld2` per job (or per group of jobs if `groups` is given)."
function write_job_files(dir, queue_file; groups = nothing)
    queue = jldopen(f -> f["queue"], queue_file, "r")
    groups = isnothing(groups) ? [[j] for j in eachindex(queue)] : groups
    for group in groups
        outputs, params = Dict{Symbol,Any}[], nothing
        for jobid in group
            params = copy(only(queue[jobid]))
            append!(outputs, [fake_output(jobid, i, params["temperature"]) for i in 1:params["trajectories"]])
        end
        params["jobid"] = length(group) == 1 ? only(group) : group
        jldsave(joinpath(dir, "trj_$(first(group)).jld2"); results = (outputs, params))
    end
    return length(queue)
end

sorted_outputs(entry) = sort(entry[1]; by = o -> o[:id])

function same_outputs(a, b)
    length(a) == length(b) || return false
    for (x, y) in zip(a, b)
        Set(keys(x)) == Set(keys(y)) || return false
        all(isequal(x[k], y[k]) for k in keys(x)) || return false
    end
    return true
end

function same_results(a, b)
    size(a) == size(b) || return false
    for i in eachindex(a)
        isassigned(a, i) == isassigned(b, i) || return false
        isassigned(a, i) || continue
        same_outputs(sorted_outputs(a[i]), sorted_outputs(b[i])) || return false
        a[i][2]["trajectories"] == b[i][2]["trajectories"] || return false
    end
    return true
end

@testset "Results database" begin
    @testset "Codec round trip" begin
        values = Any[
            1, Int8(-3), UInt64(typemax(UInt64)), 1.5, Float32(2.5), Float16(0.5), NaN, Inf, -Inf,
            true, "text", :symbol, 'c', nothing, missing, 1.0 + 2.0im,
            fill(3.0), Float64[], zeros(0, 3), rand(3, 4), rand(Int32, 2, 3, 4), Bool[1, 0, 1], rand(ComplexF64, 2),
            [rand(2, 2) for _ in 1:3], Any[rand(2, 2), rand(2, 2)], [rand(2), rand(3)], Vector{Float64}[],
            [[:a, :b], [:c]], [:a, :b, :a], ["x" "y"; "x" "z"], Any[1, 2, 3], Any[], Union{Nothing,Float64}[1.0, nothing],
            ArrayPartition(rand(3, 2), rand(3, 2)), (1, "a", [1.0]), (a = 1, b = [2.0], c = nothing),
            Dict("a" => 1, "b" => 2), Dict{String,Any}("x" => [1, 2], "y" => :z),
            UnregisteredType(1, [2.0]), [UnregisteredType(1, [2.0])],
        ]
        for compress in (true, false), value in values
            encoded = @test_logs min_level = Logging.Error CS.encode_value(value; compress = compress)
            decoded = CS.decode_value(encoded)
            @test isequal(decoded, value)
            @test typeof(decoded) == typeof(value)
        end
        big = CS.encode_value(zeros(10_000))
        @test big.codec == "zstd" && length(big.data) < big.raw_nbytes
        @test CS.encode_value(zeros(10_000); compress = false).codec == "none"
        @test CS.encode_parameter(UnregisteredType(1, [2.0])).kind == :repr
        @test CS.encode_parameter([1, 2]).kind == :array
    end

    @testset "Ingestion and queries" begin
        mktempdir() do dir
            queue_file = make_queue(dir)
            n_jobs = write_job_files(dir, queue_file)
            db_path = joinpath(dir, "results.sqlite")
            table = create_results_database(db_path, joinpath(dir, "trj_*.jld2"), queue_file; verbose = false, nthreads = 4)
            @test nrow(table) == 6
            @test all(table.fraction .== 1.0)
            @test sum(table.n_trajectories) == n_jobs

            ResultsDB(db_path) do db
                @test occursin("parameter sets: 6", sprint(show, db))
                @test query_count(db, "jobs") == n_jobs
                @test query_count(db, "trajectories") == n_jobs

                params = parameters(db)
                queue_parameters = jldopen(f -> f["parameters"], queue_file, "r")
                @test params.temperature == [p["temperature"] for p in queue_parameters]
                @test params.label == fill(:fixed, 6)
                @test parameters(db, 2)["model"] == queue_parameters[2]["model"]
                @test parameters(db, 2)["job_ids"] == queue_parameters[2]["job_ids"]

                df = scalars(db)
                @test issubset(["id", "energy", "flag", "maybe"], names(df))
                @test !("Time" in names(df))
                for row in eachrow(df)
                    temperature = queue_parameters[row.set_id]["temperature"]
                    @test row.energy == temperature + row.job_id + 0.5
                    @test row.flag == isodd(row.job_id)
                    @test isequal(row.maybe, iseven(row.job_id) ? missing : Float64(row.job_id))
                end
                @test nrow(scalars(db; keys = ["energy"], set_ids = [1, 2])) == 8

                summary = ensemble_summary(db, :energy)
                for row in eachrow(summary)
                    values = df.energy[df.set_id.==row.set_id]
                    mean = sum(values) / length(values)
                    @test row.n == length(values)
                    @test row.mean ≈ mean
                    @test row.std ≈ sqrt(sum(abs2, values .- mean) / (length(values) - 1))
                    @test row.minimum == minimum(values) && row.maximum == maximum(values)
                end
                overall = ensemble_summary(db, "maybe"; by = nothing)
                @test only(overall.n) == count(isodd, df.job_id)
                @test only(overall.n_missing) == count(iseven, df.job_id)

                frames = load_output(db, :frames)
                @test frames isa Vector{Vector{Matrix{Float64}}}
                @test length(frames) == n_jobs
                sites = load_output(db, :sites; set_id = 1)
                @test sites isa Vector{Vector{Vector{Symbol}}} && length(sites) == 4
                streamed = collect(each_output(db, :state; traj_ids = [1, 2]))
                @test [r.traj_id for r in streamed] == [1, 2]
                @test all(r -> r.value isa ArrayPartition{Float64,Tuple{Matrix{Float64},Matrix{Float64}}}, streamed)
                maybe = load_output(db, :maybe)
                @test count(isnothing, maybe) == count(iseven, df.job_id)

                trajectory = load_trajectory(db, 3)
                job_id = df.job_id[df.traj_id.==3][1]
                expected = fake_output(job_id, 1, queue_parameters[df.set_id[df.traj_id.==3][1]]["temperature"])
                @test same_outputs([trajectory], [expected])

                output_keys = keys(db)
                @test ("maybe", "scalar", "Nothing") in zip(output_keys.key, output_keys.kind, output_keys.type)
                @test only(output_keys.example_shape[output_keys.key.=="Time"]) == (11,)
            end
        end
    end

    @testset "Idempotency and corrupt files" begin
        mktempdir() do dir
            queue_file = make_queue(dir)
            n_jobs = write_job_files(dir, queue_file)
            db_path = joinpath(dir, "results.sqlite")
            create_results_database(db_path, joinpath(dir, "trj_1*.jld2"), queue_file; verbose = false)
            partial = ResultsDB(db -> query_count(db, "trajectories"), db_path)
            @test 0 < partial < n_jobs
            write(joinpath(dir, "trj_$(n_jobs + 1).jld2"), "not a JLD2 file")
            @test_logs (:warn, r"could not be read") match_mode = :any create_results_database(
                db_path, joinpath(dir, "trj_*.jld2"), queue_file; verbose = false)
            create_results_database(db_path, joinpath(dir, "trj_*.jld2"), queue_file; verbose = false, job_id_source = :in_dict)
            ResultsDB(db_path) do db
                @test query_count(db, "trajectories") == n_jobs
                @test query_count(db, "jobs") == n_jobs
                @test CS.sql_value(db.conn, "SELECT COUNT(DISTINCT job_id) FROM trajectories") == n_jobs
                @test all(completeness(db).fraction .== 1.0)
            end
        end
    end

    @testset "Threaded vs serial, legacy equivalence" begin
        mktempdir() do dir
            queue_file = make_queue(dir)
            write_job_files(dir, queue_file)
            pattern = joinpath(dir, "trj_*.jld2")
            serial, threaded = joinpath(dir, "serial.sqlite"), joinpath(dir, "threaded.sqlite")
            create_results_database(serial, pattern, queue_file; verbose = false, nthreads = 1)
            create_results_database(threaded, pattern, queue_file; verbose = false, nthreads = 4, commit_every = 3)
            serial_results = ResultsDB(to_results_array, serial)
            threaded_results = ResultsDB(to_results_array, threaded)
            @test same_results(serial_results, threaded_results)

            legacy = create_results_file(joinpath(dir, "legacy.jld2"), pattern, queue_file)
            @test same_results(legacy, serial_results)
            @test serial_results[1][2]["job_ids"] == []
        end
    end

    @testset "Shards" begin
        mktempdir() do dir
            queue_file = make_queue(dir)
            write_job_files(dir, queue_file)
            shard_dir = mkpath(joinpath(dir, "shards"))
            for file in readdir(dir; join = true)
                startswith(basename(file), "trj_") || continue
                results = jldopen(f -> f["results"], file, "r")
                write_results_shard(joinpath(shard_dir, replace(basename(file), ".jld2" => ".sqlite")), results)
            end
            @test !any(endswith(".tmp"), readdir(shard_dir))
            merged = joinpath(dir, "merged.sqlite")
            table = merge_shards!(merged, joinpath(shard_dir, "*.sqlite"), queue_file; verbose = false)
            @test all(table.fraction .== 1.0)
            direct = joinpath(dir, "direct.sqlite")
            create_results_database(direct, joinpath(dir, "trj_*.jld2"), queue_file; verbose = false)
            @test same_results(ResultsDB(to_results_array, merged), ResultsDB(to_results_array, direct))

            n_before = ResultsDB(db -> query_count(db, "trajectories"), merged)
            merge_shards!(merged, joinpath(shard_dir, "*.sqlite"), queue_file; verbose = false)
            @test ResultsDB(db -> query_count(db, "trajectories"), merged) == n_before
        end
    end

    @testset "Transform hook" begin
        mktempdir() do dir
            queue_file = make_queue(dir)
            n_jobs = write_job_files(dir, queue_file)
            db_path = joinpath(dir, "results.sqlite")
            function truncate_time(output, params)
                output = copy(output)
                output[:Time] = output[:Time][end]
                output[:energy_per_temperature] = output[:energy] / params["temperature"]
                return output
            end
            create_results_database(db_path, joinpath(dir, "trj_*.jld2"), queue_file; verbose = false, transform = truncate_time)
            ResultsDB(db_path) do db
                @test load_output(db, :Time) == fill(1.0, n_jobs)
                df = scalars(db; keys = [:Time, :energy_per_temperature, :energy])
                @test df.Time == fill(1.0, n_jobs)
                @test df.energy_per_temperature ≈ df.energy ./ parameters(db).temperature[df.set_id]
            end
        end
    end

    @testset "Batched jobs with Vector jobid" begin
        mktempdir() do dir
            queue_file = make_queue(dir; trajectories = 5, batchsize = 2)
            queue_parameters = jldopen(f -> f["parameters"], queue_file, "r")
            groups = [Int.(p["job_ids"]) for p in queue_parameters]
            @test all(length.(groups) .== 2)
            write_job_files(dir, queue_file; groups = groups)
            db_path = joinpath(dir, "results.sqlite")
            table = create_results_database(db_path, joinpath(dir, "trj_*.jld2"), queue_file; verbose = false, job_id_source = :in_dict)
            @test all(table.n_trajectories .== 5)
            @test all(table.n_jobs .== 2)
            ResultsDB(db_path) do db
                jobs = DataFrame(DBInterface.execute(db.conn, "SELECT job_id, n_trajectories FROM jobs ORDER BY job_id"))
                @test jobs.n_trajectories == repeat([2, 3], 6)
                df = scalars(db; keys = [:id])
                @test all(df.id .== 1000 .* df.job_id .+ df.local_index)
            end
        end
    end
end
