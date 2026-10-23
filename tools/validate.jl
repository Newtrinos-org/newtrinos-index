#!/usr/bin/env julia
# Validate all records (records/, candidates/) and the vocabularies.
#   julia --project tools/validate.jl [files...]
# With file arguments only those records are schema-checked (cross-references still use the whole catalogue).
# Exit code 1 on errors; warnings are printed but do not fail.
include("common.jl")
using JSONSchema

const VERIFICATIONS = joinpath(dirname(ROOT), "newtrinos-verifications", "entries")

const DETECTORS = Ref{Vector}([])

struct Report
    errors::Vector{String}
    warnings::Vector{String}
end
Report() = Report(String[], String[])
err!(r, where, msg) = push!(r.errors, "$where: $msg")
warn!(r, where, msg) = push!(r.warnings, "$where: $msg")

"First schema violation as a readable message (JSONSchema reports one issue at a time)"
function schema_issue(schema, rec)
    issue = JSONSchema.validate(schema, rec)
    issue === nothing && return nothing
    path = isempty(issue.path) ? "(top level)" : issue.path isa AbstractString ? issue.path : join(issue.path, ".")
    "schema: at $path: $(issue.reason) $(issue.val) — got $(repr(issue.x))"
end

function check_vocab(vocab, r)
    for (name, entries) in vocab
        ids = [get(e, "id", nothing) for e in entries]
        any(isnothing, ids) && err!(r, "vocab/$name.yaml", "entry without id")
        for id in unique(filter(i -> count(==(i), ids) > 1, ids))
            err!(r, "vocab/$name.yaml", "duplicate id $id")
        end
    end
    # experiment registry: valid references and unambiguous names/aliases
    exps = vocab["experiments"]
    ids = Set(e["id"] for e in exps)
    sources = Set(e["id"] for e in vocab["sources"])
    techs = Set(e["id"] for e in vocab["detector_technologies"])
    names = Dict{String, String}()
    for e in exps
        w = "vocab/experiments.yaml[$(e["id"])]"
        for k in ("predecessor", "successor")
            haskey(e, k) && !(e[k] in ids) && err!(r, w, "$k $(e[k]) is not an experiment id")
        end
        for s in get(e, "sources", []); s in sources || err!(r, w, "unknown source $s"); end
        for t in get(e, "technology", []); t in techs || err!(r, w, "unknown technology $t"); end
        for d in get(e, "detectors", []), n in unique(lowercase.(vcat(d["id"], get(d, "aliases", String[]))))
            haskey(names, n) && names[n] != e["id"] && err!(r, w, "detector name/alias \"$n\" also used by $(names[n])")
            names[n] = e["id"]
        end
        for n in unique(lowercase.(vcat(e["id"], e["name"], get(e, "aliases", String[]))))
            haskey(names, n) && names[n] != e["id"] && err!(r, w, "name/alias \"$n\" also used by $(names[n])")
            names[n] = e["id"]
        end
    end
end

function check_records(records, schema, only, r)
    ids = Dict{String, String}()
    dois = Dict{String, String}()
    for (path, rec) in records
        rel = relpath(path, ROOT)
        id = get(rec, "id", "")
        # file layout: <dir>/<type>/<id>.yaml
        splitext(basename(path))[1] == id || err!(r, rel, "id \"$id\" does not match the file name")
        basename(dirname(path)) == get(rec, "type", "") || err!(r, rel, "type \"$(get(rec, "type", ""))\" does not match the folder")
        haskey(ids, id) && err!(r, rel, "duplicate id (also $(ids[id]))")
        ids[id] = rel
        if haskey(rec, "doi")
            d = lowercase(rec["doi"])
            haskey(dois, d) && err!(r, rel, "DOI $(rec["doi"]) also used by $(dois[d])")
            dois[d] = rel
        end
        if isempty(only) || abspath(path) in only
            msg = schema_issue(schema, rec)
            msg === nothing || err!(r, rel, msg)
        end
        # curation sanity
        cur = get(rec, "curation", Dict())
        startswith(rel, "candidates") && get(cur, "status", "") != "candidate" && err!(r, rel, "records in candidates/ must have curation.status candidate")
        startswith(rel, "records") && get(cur, "status", "") == "candidate" && warn!(r, rel, "candidate record in records/ (move to candidates/ or curate)")
        any(d -> d["role"] == "primary", get(rec, "distributions", [])) || warn!(r, rel, "no distribution with role primary")
        get(rec, "access", "") == "open" && get(rec, "license", "") in ("unknown",) && warn!(r, rel, "open access but licence not checked yet")
        for d in get(rec, "detectors", [])
            i = findfirst(x -> x["id"] == d, DETECTORS[])
            i === nothing && continue    # unknown ids are reported by the schema
            DETECTORS[][i]["experiment"] in get(rec, "experiments", []) ||
                err!(r, rel, "detector $d belongs to $(DETECTORS[][i]["experiment"]), which is not in experiments")
        end
    end
    # cross-references
    for (path, rec) in records
        rel = relpath(path, ROOT)
        for x in get(rec, "relations", [])
            t = x["target"]
            startswith(t, "doi:") || startswith(t, "http") || haskey(ids, t) || err!(r, rel, "relation $(x["rel"]) → unknown record \"$t\"")
        end
        for key in ("uses", "used_by"), x in get(rec, key, [])
            t = x["target"]
            haskey(ids, t) && (err!(r, rel, "$key → $t is a catalogue record: use relations ($(key == "uses" ? "uses: $t here" : "uses: $(rec["id"]) on $t"))"); continue)
            occursin(r"^(doi:10\.|arXiv:|https?://)"i, t) || err!(r, rel, "$key → \"$t\" must be doi:, arXiv: or a URL")
        end
        if isdir(VERIFICATIONS)
            for v in get(get(rec, "newtrinos", Dict()), "verifications", [])
                isdir(joinpath(VERIFICATIONS, v)) || warn!(r, rel, "verification entry $v not found in $(VERIFICATIONS)")
            end
        end
    end
    # relations are stated on one side only; the site derives the inverse (has_part ↔ is_part_of, uses ↔ used_by, ...)
end

function main(args)
    r = Report()
    vocab = load_vocab()
    DETECTORS[] = vocab["detectors"]
    check_vocab(vocab, r)
    schema_text(build_schema(vocab)) == (isfile(SCHEMA_JSON) ? read(SCHEMA_JSON, String) : "") ||
        err!(r, "schema/record.schema.json", "out of date: run julia --project tools/gen_schema.jl")
    schema = JSONSchema.Schema(JSON.parsefile(SCHEMA_JSON))
    files = filter(a -> !startswith(a, "--"), args)
    only = Set(abspath.(files))
    records = load_records()
    # explicitly named files outside records/ and candidates/ (e.g. test/) are validated on their own
    extra = [(f, loadyaml(f)) for f in abspath.(files) if !any(p -> p[1] == f, records)]
    check_records(vcat(records, extra), schema, only, r)
    foreach(w -> println("warning: ", w), r.warnings)
    foreach(e -> println("ERROR: ", e), r.errors)
    n = isempty(only) ? length(records) : length(only)
    println("$(n) record(s) checked: $(length(r.errors)) error(s), $(length(r.warnings)) warning(s)")
    isempty(r.errors) ? 0 : 1
end

abspath(PROGRAM_FILE) == (@__FILE__) && exit(main(ARGS))
