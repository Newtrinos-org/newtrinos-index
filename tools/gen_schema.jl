#!/usr/bin/env julia
# Generate schema/record.schema.json from schema/record.schema.yaml + vocab/*.yaml.
#   julia --project tools/gen_schema.jl          write the JSON schema
#   julia --project tools/gen_schema.jl --check  fail if the committed JSON schema is out of date
include("common.jl")

txt = schema_text(build_schema())
if "--check" in ARGS
    current = isfile(SCHEMA_JSON) ? read(SCHEMA_JSON, String) : ""
    current == txt || (println(stderr, "schema/record.schema.json is out of date: run julia --project tools/gen_schema.jl"); exit(1))
    println("schema up to date")
else
    write(SCHEMA_JSON, txt)
    println("wrote $(relpath(SCHEMA_JSON, ROOT))")
end
