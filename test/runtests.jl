# Validator tests: every test/good/*.yaml must pass, every test/bad/*.yaml must fail with the message given in its
# first line (`# expect: <substring>`).   julia --project test/runtests.jl
include(joinpath(dirname(@__DIR__), "tools", "validate.jl"))
using Test

const SCHEMA = JSONSchema.Schema(JSON.parsefile(SCHEMA_JSON))
dir(d) = sort(filter(f -> endswith(f, ".yaml"), readdir(joinpath(@__DIR__, d), join = true)))

@testset "validator" begin
    @testset "good: $(basename(f))" for f in dir("good")
        @test schema_issue(SCHEMA, loadyaml(f)) === nothing
    end
    @testset "bad: $(basename(f))" for f in dir("bad")
        expect = strip(replace(readline(f), "# expect:" => ""))
        msg = schema_issue(SCHEMA, loadyaml(f))
        @test msg !== nothing && occursin(expect, msg)
    end
    @testset "catalogue" begin
        r = Report()
        vocab = load_vocab()
        DETECTORS[] = vocab["detectors"]
        check_vocab(vocab, r)
        check_records(load_records(), SCHEMA, Set{String}(), r)
        @test isempty(r.errors)
        foreach(println, r.errors)
    end
end
