# Shared helpers for the Newtrinos Index tools: loading vocabularies and records, building the JSON Schema.
using YAML, JSON, Dates

const ROOT = dirname(@__DIR__)
const RECORD_DIRS = ["records", "candidates"]
const TYPES = ["dataset", "result", "model", "software", "service", "collection"]

"YAML → plain JSON-compatible values (dates as ISO strings, Dict{String,Any})"
plain(x::AbstractDict) = Dict{String, Any}(string(k) => plain(v) for (k, v) in x)
plain(x::AbstractVector) = Any[plain(v) for v in x]
plain(x::Union{Date, DateTime}) = Dates.format(x, x isa Date ? "yyyy-mm-dd" : "yyyy-mm-ddTHH:MM:SS")
plain(x) = x

loadyaml(path) = plain(YAML.load_file(path))

"vocab name → vector of entries (each a Dict with at least `id`); `detectors` is derived from the experiment registry"
function load_vocab()
    v = Dict(splitext(f)[1] => loadyaml(joinpath(ROOT, "vocab", f)) for f in readdir(joinpath(ROOT, "vocab")) if endswith(f, ".yaml"))
    v["detectors"] = [merge(d, Dict("experiment" => e["id"], "label" => "$(e["name"]) $(d["name"])"))
                      for e in v["experiments"] for d in get(e, "detectors", [])]
    v
end

"All record files: (path, record) for records/<type>/<id>.yaml and candidates/<type>/<id>.yaml"
function load_records(; dirs = RECORD_DIRS)
    out = Tuple{String, Dict{String, Any}}[]
    for d in filter(d -> isdir(joinpath(ROOT, d)), dirs), (root, _, files) in walkdir(joinpath(ROOT, d)), f in sort(files)
        endswith(f, ".yaml") && push!(out, (joinpath(root, f), loadyaml(joinpath(root, f))))
    end
    out
end

"Expand `{\$vocab: name}` markers in the schema source into enums of the vocabulary ids"
function expand_vocab(x, vocab)
    if x isa AbstractDict
        if haskey(x, "\$vocab")
            name = x["\$vocab"]
            haskey(vocab, name) || error("schema refers to unknown vocabulary $name")
            rest = Dict(k => v for (k, v) in x if k != "\$vocab")
            return merge(rest, Dict{String, Any}("enum" => [e["id"] for e in vocab[name]], "x-vocab" => name))
        end
        return Dict{String, Any}(k => expand_vocab(v, vocab) for (k, v) in x)
    end
    x isa AbstractVector && return Any[expand_vocab(v, vocab) for v in x]
    x
end

const SCHEMA_SRC = joinpath(ROOT, "schema", "record.schema.yaml")
const SCHEMA_JSON = joinpath(ROOT, "schema", "record.schema.json")

build_schema(vocab = load_vocab()) = expand_vocab(loadyaml(SCHEMA_SRC), vocab)
"Deterministic pretty JSON: object keys sorted, 2-space indent (so generated files diff cleanly)"
function sorted_json(x, ind = "")
    i2 = ind * "  "
    if x isa AbstractDict
        isempty(x) && return "{}"
        return "{\n" * join(["$i2$(JSON.json(string(k))): $(sorted_json(x[k], i2))" for k in sort(collect(keys(x)), by = string)], ",\n") * "\n$ind}"
    elseif x isa AbstractVector
        isempty(x) && return "[]"
        all(v -> !(v isa AbstractDict || v isa AbstractVector), x) && return "[" * join(JSON.json.(x), ", ") * "]"
        return "[\n" * join(["$i2$(sorted_json(v, i2))" for v in x], ",\n") * "\n$ind]"
    end
    JSON.json(x)
end
schema_text(schema) = sorted_json(schema) * "\n"

# ------------------------------------------------------------------------------------------------
# minimal YAML writer (keeps key order of OrderedDicts; used by the scaffolding and harvest tools)
# ------------------------------------------------------------------------------------------------
using OrderedCollections

const YAML_PLAIN = r"^[A-Za-z0-9_][A-Za-z0-9_ ./()+,'-]*$"
function yaml_scalar(x)
    x === nothing && return "null"
    x isa Bool && return string(x)
    x isa Integer && return string(x)
    x isa AbstractFloat && return string(x)
    s = string(x)
    reserved = lowercase(s) in ("true", "false", "yes", "no", "null", "on", "off", "~")
    numeric = occursin(r"^[-+]?[0-9.eE_:-]+$", s)       # numbers, dates, times
    (occursin(YAML_PLAIN, s) && !reserved && !numeric && !endswith(s, " ")) ? s : JSON.json(s)
end

function yaml_lines!(out, x, ind)
    pad = " "^ind
    if x isa AbstractDict
        for (k, v) in x
            if v isa AbstractDict && !isempty(v) || v isa AbstractVector && !isempty(v) && !all(isscalar, v)
                push!(out, "$pad$k:")
                yaml_lines!(out, v, ind + 2)
            elseif v isa AbstractVector
                push!(out, "$pad$k: [" * join(yaml_scalar.(v), ", ") * "]")
            elseif v isa AbstractString && occursin('\n', v)
                push!(out, "$pad$k: |-")
                append!(out, [isempty(l) ? "" : "$pad  $l" for l in split(rstrip(v), '\n')])
            else
                push!(out, "$pad$k: $(v isa AbstractDict ? "{}" : yaml_scalar(v))")
            end
        end
    elseif x isa AbstractVector
        for v in x
            if v isa AbstractDict
                sub = String[]
                yaml_lines!(sub, v, ind + 2)
                isempty(sub) && (push!(out, "$pad- {}"); continue)
                push!(out, "$pad- " * lstrip(sub[1]))
                append!(out, sub[2:end])
            else
                push!(out, "$pad- $(yaml_scalar(v))")
            end
        end
    end
    out
end
isscalar(v) = !(v isa AbstractDict || v isa AbstractVector)
to_yaml(x) = join(yaml_lines!(String[], x, 0), "\n") * "\n"
