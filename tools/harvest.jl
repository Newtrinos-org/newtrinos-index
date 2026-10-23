#!/usr/bin/env julia
# Harvest candidate records from public registries into candidates/ (never into records/).
#   julia --project tools/harvest.jl [datacite] [dataverse] [hepdata] [github] [--dry] [--limit=N]
# Without source arguments all sources run. Every hit is filtered (resource type, exclusions, neutrino relevance),
# deduplicated against records/ and candidates/ (DOIs incl. Zenodo concept DOIs, URLs, titles), tagged with
# experiments / detectors / sources / topics from the registry and keyword rules, and written as a candidate.
# A summary goes to candidates/HARVEST.md. Configuration: tools/harvest/config.toml.
include("new_record.jl")
using TOML

const CFG = TOML.parsefile(joinpath(@__DIR__, "harvest", "config.toml"))
const VOCAB = load_vocab()
sleepy(s = 1.0) = sleep(s)                     # be polite: the public APIs throttle quickly

# raw API responses are cached for a day in .harvest_cache/ (gitignored), so reruns while tuning filters are cheap
using SHA
const CACHE = joinpath(ROOT, ".harvest_cache")
# HEPData's Cloudflare front end rejects HTTP.jl requests but serves curl, which its API documentation uses
curljson(url) = try JSON.parse(read(`curl -sS -m 60 $url`, String)) catch e; @warn "request failed" url exception = e; nothing end
function cachedjson(url; fetch = tryjson)
    mkpath(CACHE)
    f = joinpath(CACHE, bytes2hex(sha1(url)) * ".json")
    isfile(f) && time() - mtime(f) < 86400 && return JSON.parsefile(f)
    d = fetch(url)
    d === nothing || write(f, JSON.json(d))
    d
end

# ------------------------------------------------------------------------------------------------
# matching against the registry
# ------------------------------------------------------------------------------------------------
"(regex, experiment id, detector id or nothing) for every official name and alias, matched case-sensitively as whole words
(ids are not used: many are ordinary words, e.g. best, coherent, sage)"
const NAME_PATTERNS = let out = Tuple{Regex, String, Union{String, Nothing}}[]
    esc(n) = replace(n, r"([.+*?()\[\]{}|^$\\/])" => s"\\\1")
    add(n, e, d) = length(strip(n)) >= 2 && push!(out, (Regex("(?<![A-Za-z0-9])" * esc(strip(n)) * "(?![A-Za-z0-9])"), e, d))
    for e in VOCAB["experiments"]
        for n in vcat(e["name"], get(e, "aliases", String[])); add(n, e["id"], nothing); end
        for d in get(e, "detectors", []), n in vcat(d["name"], get(d, "aliases", String[])); add(n, e["id"], d["id"]); end
    end
    sort!(out, by = x -> -length(x[1].pattern))
end
function match_experiments(text)
    exps, dets = String[], String[]
    for (re, e, d) in NAME_PATTERNS
        occursin(re, text) || continue
        e in exps || push!(exps, e)
        d === nothing || d in dets || push!(dets, d)
    end
    exps, dets
end

const SOURCE_RULES = [r"solar"i => "solar", r"atmospheric"i => "atmospheric", r"reactor"i => "reactor",
    r"accelerator|beam|NuMI|BNB|J-PARC"i => "accelerator", r"geo-?neutrino"i => "geo", r"supernova|DSNB"i => "supernova",
    r"astrophysical|point[- ]source|blazar|galactic|AGN|cosmic neutrino|alert"i => "astrophysical",
    r"spallation|SNS|stopped[- ]pion|CEvNS"i => "spallation", r"double[- ]beta|0νββ|neutrinoless|tritium|KATRIN"i => "nuclear-decay"]
const TOPIC_RULES = [r"oscillation"i => "oscillation", r"mass ordering|hierarchy"i => "mass-ordering", r"CP[- ]viol|δ_?CP|delta_?cp"i => "cp-violation",
    r"cross[- ]section|interaction"i => "cross-section", r"sterile"i => "sterile", r"non[- ]standard interaction|\bNSI\b"i => "nsi",
    r"dark matter|WIMP"i => "dark-matter", r"decoherence"i => "decoherence", r"flux"i => "flux", r"double[- ]beta|neutrinoless"i => "double-beta",
    r"neutrino mass"i => "absolute-mass", r"point[- ]source|multi-?messenger|alert|gravitational"i => "multi-messenger",
    r"Lorentz"i => "lorentz-violation", r"magnetic moment"i => "magnetic-moment"]
const LEVEL_RULES = [r"Monte Carlo|simulation|\bMC\b"i => "mc", r"\bevents?\b|catalog"i => "events", r"posterior|MCMC|chains?\b"i => "posterior",
    r"effective area|response|efficienc"i => "response", r"likelihood|χ2|chi2|chi-square"i => "likelihood", r"contour|limit"i => "contours",
    r"covariance|systematic"i => "systematics"]
rules(rs, text) = unique([v for (re, v) in rs if occursin(re, text)])

const EXCLUDE = [Regex(p, "i") for p in CFG["filters"]["exclude_title"]]
const NUKEYS = [Regex(p, "i") for p in CFG["filters"]["neutrino_keywords"]]

# ------------------------------------------------------------------------------------------------
# what is already catalogued
# ------------------------------------------------------------------------------------------------
function normurl(u)
    u = rstrip(lowercase(replace(strip(u), r"^https?://(www\.)?" => "")), '/')
    m = match(r"^github\.com/([^/]+)/([^/#?]+)", u)           # any GitHub URL → the repository
    m === nothing ? u : "github.com/$(m[1])/$(replace(m[2], r"\.git$" => ""))"
end
normtitle(t) = replace(lowercase(t), r"[^a-z0-9]+" => "")
struct Known
    dois::Set{String}
    urls::Set{String}
    titles::Set{String}
    ids::Set{String}
end
function Known()
    k = Known(Set(), Set(), Set(), Set())
    for (_, r) in load_records()
        push!(k.ids, r["id"]); push!(k.titles, normtitle(r["title"]))
        haskey(r, "doi") && push!(k.dois, lowercase(r["doi"]), replace(lowercase(r["doi"]), r"\.v\d+$" => ""))
        for v in get(r, "versions", []); haskey(v, "doi") && push!(k.dois, lowercase(v["doi"])); end
        for d in r["distributions"]
            push!(k.urls, normurl(d["url"]))
            m = match(r"doi\.org/(10\..+)$"i, d["url"]); m === nothing || push!(k.dois, lowercase(m[1]))
        end
        haskey(r, "url_landing") && push!(k.urls, normurl(r["url_landing"]))
        haskey(r, "software") && haskey(r["software"], "repository") && push!(k.urls, normurl(r["software"]["repository"]))
    end
    k
end
known(k::Known, c) = replace(lowercase(get(c.rec, "doi", "")), r"\.v\d+$" => "") in k.dois || any(d -> d in k.dois, c.alt_dois) ||
                     any(u -> normurl(u) in k.urls, c.urls) || normtitle(c.rec["title"]) in k.titles

# ------------------------------------------------------------------------------------------------
# a harvested hit
# ------------------------------------------------------------------------------------------------
mutable struct Hit
    rec::OrderedDict{String, Any}
    source::String
    query::String
    text::String                  # title + description + creators + subjects, for matching
    urls::Vector{String}
    alt_dois::Vector{String}      # concept / other version DOIs (lower case)
    metrics::OrderedDict{String, Any}
end
score(h) = 10 * get(h.metrics, "citations", 0) + get(h.metrics, "downloads", 0) / 20 + get(h.metrics, "views", 0) / 200 + 2 * get(h.metrics, "stars", 0)

# ------------------------------------------------------------------------------------------------
# sources
# ------------------------------------------------------------------------------------------------
function datacite_hit(item, query)
    a = item["attributes"]; doi = lowercase(a["doi"])
    rtype = get(a["types"], "resourceTypeGeneral", "")
    rtype in CFG["filters"]["resource_types"] || return nothing
    occursin(r"/t\d+$", doi) && return nothing                       # single HEPData tables
    rec = try from_datacite(a, doi; enrich = false) catch e; @warn "skipped" doi exception = e; return nothing end
    alt = [lowercase(bare_doi(r["relatedIdentifier"])) for r in get(a, "relatedIdentifiers", [])
           if get(r, "relatedIdentifierType", "") == "DOI" && get(r, "relationType", "") in ("IsVersionOf", "HasVersion", "IsIdenticalTo", "IsNewVersionOf", "IsPreviousVersionOf")]
    text = join(vcat(rec["title"], rec["description"], [c["name"] for c in a["creators"]], [s["subject"] for s in get(a, "subjects", [])]), " \n ")
    rel_urls = [r["relatedIdentifier"] for r in get(a, "relatedIdentifiers", []) if get(r, "relatedIdentifierType", "") == "URL"]
    Hit(rec, "datacite", query, text, vcat(get(a, "url", ""), rel_urls), alt,
        OrderedDict("citations" => get(a, "citationCount", 0), "views" => get(a, "viewCount", 0), "downloads" => get(a, "downloadCount", 0)))
end

function datacite_query(q; max = CFG["datacite"]["max_per_query"])
    types = join(["types.resourceTypeGeneral:$t" for t in CFG["filters"]["resource_types"]], " OR ")
    url = "https://api.datacite.org/dois?query=" * HTTP.escapeuri("($q) AND ($types)") * "&page[size]=100&page[cursor]=1"
    hits = Hit[]
    while url !== nothing && length(hits) < max
        d = cachedjson(url); d === nothing && break
        for item in d["data"]
            h = datacite_hit(item, q); h === nothing || push!(hits, h)
        end
        url = get(get(d, "links", Dict()), "next", nothing); sleepy(0.5)
    end
    hits
end

function harvest_datacite()
    c = CFG["datacite"]; qs = String[]
    if c["by_collaboration"]
        for e in VOCAB["experiments"]
            push!(qs, "creators.name:\"$(get(e, "collaboration", e["name"])) Collaboration\"")
        end
    end
    append!(qs, ["doi:$(p)/*" for p in c["prefixes"]])
    append!(qs, c["queries"])
    hits = Hit[]
    for q in unique(qs)
        h = datacite_query(q); append!(hits, h); println("  datacite $(rpad(first(q, 70), 70)) $(length(h))")
    end
    hits
end

function harvest_dataverse()
    hits = Hit[]
    for dv in CFG["dataverse"]
        url = "$(dv["base"])/api/search?q=*&type=dataset&per_page=100" * (isempty(dv["subtree"]) ? "" : "&subtree=$(dv["subtree"])")
        d = cachedjson(url); d === nothing && continue
        for i in d["data"]["items"]
            doi = lowercase(replace(get(i, "global_id", ""), r"^doi:" => ""))
            isempty(doi) && continue
            rec, a = nothing, nothing
            if !startswith(doi, "10.5072")                  # test DOIs are not in DataCite
                g = cachedjson("https://api.datacite.org/dois/$(HTTP.escapeuri(doi))"); sleepy(0.1)
                g === nothing || (a = g["data"]["attributes"]; rec = from_datacite(a, doi; enrich = true))
            end
            if rec === nothing                              # build from the Dataverse search record
                rec = OrderedDict{String, Any}("id" => slug(i["name"]), "type" => "dataset", "title" => i["name"], "short" => first(i["name"], 120),
                    "description" => strip(get(i, "description", i["name"])), "url_landing" => i["url"],
                    "creators" => [OrderedDict("name" => n) for n in get(i, "authors", [])], "date_published" => get(i, "published_at", "")[1:min(end, 10)],
                    "license" => "unknown", "access" => "open",
                    "distributions" => [OrderedDict("url" => i["url"], "host" => "dataverse", "role" => "primary")])
            end
            text = join(vcat(rec["title"], rec["description"], get(i, "authors", []), get(i, "keywords", []), dv["subtree"]), " \n ")
            push!(hits, Hit(rec, "dataverse", "$(dv["base"]) $(dv["subtree"])", text, [i["url"]], String[], OrderedDict()))
        end
        println("  dataverse $(dv["base"]) $(dv["subtree"]): $(length(d["data"]["items"]))")
    end
    hits
end

function harvest_hepdata()
    hits = Hit[]
    for c in CFG["hepdata"]["collaborations"]
        page = 1; n = 0
        while true
            d = cachedjson("https://www.hepdata.net/search/?collaboration=$(HTTP.escapeuri(c))&format=json&size=100&page=$page"; fetch = curljson); sleepy(0.5)
            (d === nothing || isempty(get(d, "results", []))) && break
            for r in d["results"]
                ins = get(r, "inspire_id", nothing); ins === nothing && continue
                doi = lowercase(get(r, "hepdata_doi", get(r, "doi", "")))
                title = strip(get(r, "title", "HEPData ins$ins"))
                url = "https://www.hepdata.net/record/ins$ins"
                rec = OrderedDict{String, Any}("id" => slug("hepdata " * title), "type" => "dataset", "title" => "HEPData: " * title,
                    "short" => first("HEPData: " * title, 120), "description" => strip(get(r, "abstract", title)), "url_landing" => url,
                    "creators" => [OrderedDict("name" => "$c Collaboration", "kind" => "collaboration")],
                    "date_published" => first(string(get(r, "year", get(r, "date", ""))), 4),
                    "license" => "CC0-1.0", "license_notes" => "HEPData records are CC0", "access" => "open",
                    "distributions" => [OrderedDict("url" => url, "host" => "hepdata", "role" => "primary", "formats" => ["yaml", "csv", "json", "root"])],
                    "identifiers" => OrderedDict("inspire" => parse(Int, string(ins)), "hepdata" => "ins$ins"),
                    "relations" => [OrderedDict("rel" => "is_part_of", "target" => "hepdata")])
                isempty(doi) || (rec["doi"] = replace(doi, r"\.v\d+$" => ""))
                pdoi = get(r, "doi", nothing)
                if pdoi isa AbstractString && !startswith(lowercase(pdoi), "10.17182")
                    rec["references"] = [OrderedDict("doi" => pdoi, "relation" => "describes")]
                end
                push!(hits, Hit(rec, "hepdata", c, join([rec["title"], rec["description"], "$c Collaboration"], " \n "), [url],
                                isempty(doi) ? String[] : [doi], OrderedDict()))
                n += 1
            end
            length(d["results"]) < 100 && break
            page += 1
        end
        println("  hepdata $(rpad(c, 18)) $n")
    end
    hits
end

function harvest_github()
    c = CFG["github"]; hits = Hit[]
    qs = vcat(["topic:$t stars:>=$(c["min_stars"])" for t in c["topics"]], c["queries"])
    for q in qs
        d = cachedjson("https://api.github.com/search/repositories?q=$(HTTP.escapeuri(q))&sort=stars&per_page=100"); sleepy(7)   # search API: 10/min
        d === nothing && continue
        for repo in d["items"]
            rec = from_github_repo(repo)
            text = join(vcat(repo["full_name"], something(repo["description"], ""), get(repo, "topics", [])), " \n ")
            push!(hits, Hit(rec, "github", q, text, [repo["html_url"]], String[], OrderedDict("stars" => repo["stargazers_count"])))
        end
        println("  github $(rpad(q, 50)) $(length(d["items"]))")
    end
    hits
end

# ------------------------------------------------------------------------------------------------
# filtering, tagging, writing
# ------------------------------------------------------------------------------------------------
function classify!(h::Hit)
    r = h.rec
    exps, dets = match_experiments(h.text)
    r["experiments"] = exps
    isempty(dets) || (r["detectors"] = dets)
    srcs = rules(SOURCE_RULES, h.text)
    if isempty(srcs) && length(exps) == 1
        e = VOCAB["experiments"][findfirst(x -> x["id"] == exps[1], VOCAB["experiments"])]
        length(e["sources"]) == 1 && (srcs = e["sources"])
    end
    r["sources"] = isempty(srcs) ? ["none"] : srcs
    r["topics"] = rules(TOPIC_RULES, h.text)
    if r["type"] in ("dataset", "result")
        lv = h.source == "hepdata" ? ["summary"] : rules(LEVEL_RULES, h.text)
        r["data"] = OrderedDict("levels" => isempty(lv) ? ["binned"] : lv)
    end
    if r["type"] == "software"
        sw = get!(r, "software", OrderedDict{String, Any}())
        sw["purposes"] = ["tooling"]
        haskey(sw, "repository") || (sw["repository"] = r["distributions"][1]["url"])
    end
    r["type"] == "collection" && (r["type"] = "dataset"; r["data"] = OrderedDict("levels" => ["summary"]))  # HEPData "Collection" = one paper
    h
end

relevant(h) = !any(re -> occursin(re, h.rec["title"]), EXCLUDE) &&
              (any(re -> occursin(re, h.text), NUKEYS) || !isempty(h.rec["experiments"]))

function finalize(h::Hit, ids)
    r = h.rec
    isempty(r["id"]) && (r["id"] = "candidate-" * bytes2hex(sha1(r["title"]))[1:10])   # titles without Latin letters
    base = r["id"]; id = base; i = 2
    while id in ids; id = "$base-$i"; i += 1; end
    push!(ids, id); r["id"] = id
    # the schema needs non-empty, valid fields
    isempty(strip(r["description"])) && (r["description"] = r["title"])
    r["short"] = first(replace(r["short"], '\n' => ' '), 120)
    get(r, "license", "unknown") in [v["id"] for v in VOCAB["licenses"]] || (r["license"] = "unknown")
    m = OrderedDict{String, Any}("source" => h.source, "query" => h.query, "harvested" => today(), "score" => round(score(h), digits = 1))
    merge!(m, h.metrics)
    r["curation"] = OrderedDict{String, Any}("status" => "candidate", "added" => today(), "source" => "harvest:$(h.source)", "harvest" => m)
    r
end

function main(args)
    sources = filter(a -> !startswith(a, "--"), args)
    isempty(sources) && (sources = ["datacite", "dataverse", "hepdata", "github"])
    lim = filter(a -> startswith(a, "--limit="), args)
    limit = isempty(lim) ? 0 : parse(Int, lim[1][9:end])
    fns = Dict("datacite" => harvest_datacite, "dataverse" => harvest_dataverse, "hepdata" => harvest_hepdata, "github" => harvest_github)
    k = Known()
    hits = Hit[]
    for s in sources
        println("[$s]"); append!(hits, fns[s]())
    end
    n_raw = length(hits)
    # one hit per resource: DOI / concept DOI / URL / title within this run, then against the catalogue
    seen = Set{String}(); uniq = Hit[]
    for h in sort(hits, by = score, rev = true)
        keys = vcat(lowercase(get(h.rec, "doi", "")), h.alt_dois, normurl.(h.urls), normtitle(h.rec["title"]))
        any(x -> !isempty(x) && x in seen, keys) && continue
        union!(seen, filter(!isempty, keys)); push!(uniq, h)
    end
    classify!.(uniq)
    new = filter(h -> !known(k, h), uniq)
    dropped = filter(h -> !relevant(h), new)
    keep = filter(relevant, new)
    limit > 0 && (keep = keep[1:min(end, limit)])
    ids = copy(k.ids)
    recs = [finalize(h, ids) for h in keep]
    println("\n$n_raw hits → $(length(uniq)) unique → $(length(new)) not yet catalogued → $(length(keep)) relevant candidates ($(length(dropped)) dropped by filters)")
    "--dry" in args && return
    for r in recs
        p = joinpath(ROOT, "candidates", r["type"], r["id"] * ".yaml"); mkpath(dirname(p))
        write(p, "# harvested by tools/harvest.jl on $(today()); review before moving to records/\n" * to_yaml(r))
    end
    open(joinpath(ROOT, "candidates", "HARVEST.md"), "w") do io
        println(io, "# Harvest $(today())\n\nSources: $(join(sources, ", ")). $n_raw hits, $(length(uniq)) unique, $(length(new)) not yet catalogued, ",
                "$(length(recs)) candidates written, $(length(dropped)) dropped by the filters.\n")
        for (title, sel) in (("Matching a registry experiment", r -> !isempty(r["experiments"])),
                             ("No experiment match (review quickly; most noise is here)", r -> isempty(r["experiments"])))
        println(io, "\n## $title\n\n| score | candidate | type | experiments | source |\n|---:|---|---|---|---|")
        for r in filter(sel, recs)
            println(io, "| $(r["curation"]["harvest"]["score"]) | [$(replace(r["title"], "|" => "/"))]($(r["type"])/$(r["id"]).yaml) | $(r["type"]) | ",
                    "$(join(r["experiments"], ", ")) | $(r["curation"]["harvest"]["source"]) |")
        end
        end
        println(io, "\n## Dropped by filters (sample)\n")
        for h in dropped[1:min(end, 200)]; println(io, "- $(replace(h.rec["title"], "|" => "/")) ($(h.source))"); end
    end
    println("wrote $(length(recs)) candidates and candidates/HARVEST.md")
end

abspath(PROGRAM_FILE) == (@__FILE__) && main(ARGS)
