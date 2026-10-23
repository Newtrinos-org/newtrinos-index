#!/usr/bin/env julia
# Scaffold a record from a DOI (DataCite, plus the Zenodo API for file lists) or a GitHub repository URL.
#   julia --project tools/new_record.jl <doi | https://doi.org/... | https://github.com/owner/repo> [--id=slug] [--type=dataset] [--write]
# Prints the YAML (or writes candidates/<type>/<id>.yaml with --write). The physics classification, the card and
# anything the APIs do not know are left for the curator; harvested values are only a starting point.
include("common.jl")
using HTTP

const UA = ["User-Agent" => "newtrinos-index (https://github.com/Newtrinos-org/newtrinos-index)"]
getjson(url; headers = []) = JSON.parse(String(HTTP.get(url, vcat(UA, headers); read_idle_timeout = 60, retries = 2).body))
tryjson(url; kw...) = try getjson(url; kw...) catch e; @warn "request failed" url exception = e; nothing end

today() = Dates.format(Dates.today(), "yyyy-mm-dd")
slug(s) = strip(first(strip(replace(lowercase(s), r"[^a-z0-9]+" => "-"), '-'), 60), '-')
striphtml(s) = strip(replace(replace(s, r"<br\s*/?>|</p>" => "\n"), r"<[^>]+>" => "", "&nbsp;" => " ", "&amp;" => "&", r"\n{3,}" => "\n\n"))

const EXT_FORMAT = Dict("csv" => "csv", "tsv" => "csv", "txt" => "txt", "dat" => "txt", "json" => "json", "yaml" => "yaml",
    "yml" => "yaml", "toml" => "toml", "h5" => "hdf5", "hdf5" => "hdf5", "hdf" => "hdf5", "root" => "root", "fits" => "fits",
    "npy" => "npy", "npz" => "npy", "parquet" => "parquet", "pkl" => "pickle", "pickle" => "pickle", "jld2" => "jld2",
    "xml" => "xml", "pdf" => "pdf", "png" => "image", "svg" => "image", "eps" => "image", "xlsx" => "xlsx",
    "zip" => "tarball", "gz" => "tarball", "tgz" => "tarball", "tar" => "tarball", "xz" => "tarball", "bz2" => "tarball",
    "py" => "source-code", "jl" => "source-code", "c" => "source-code", "cpp" => "source-code", "f" => "source-code")
function guess_format(name)
    m = match(r"_(csv|tsv|npz|npy|root|hdf5|h5|json|txt)[_.]", lowercase(name))   # e.g. dataset_root_1-0-0.zip
    m !== nothing && return EXT_FORMAT[m[1]]
    get(EXT_FORMAT, lowercase(last(split(name, '.'))), "binary")
end

const LICENSE_MAP = Dict("cc-by-4.0" => "CC-BY-4.0", "cc-by-3.0" => "CC-BY-3.0", "cc0-1.0" => "CC0-1.0", "cc-by-sa-4.0" => "CC-BY-SA-4.0",
    "cc-by-nc-4.0" => "CC-BY-NC-4.0", "mit" => "MIT", "apache-2.0" => "Apache-2.0", "bsd-3-clause" => "BSD-3-Clause",
    "bsd-2-clause" => "BSD-2-Clause", "gpl-3.0" => "GPL-3.0-only", "gpl-3.0-only" => "GPL-3.0-only", "gpl-3.0-or-later" => "GPL-3.0-or-later",
    "gpl-2.0" => "GPL-2.0-only", "lgpl-3.0" => "LGPL-3.0-or-later", "mpl-2.0" => "MPL-2.0", "odbl-1.0" => "ODbL-1.0")
spdx(id) = get(LICENSE_MAP, lowercase(string(id)), "unknown")
"Licence from a Creative Commons / opensource.org URL when DataCite gives no SPDX id"
function spdx_from_url(u)
    m = match(r"creativecommons\.org/(licenses|publicdomain)/([a-z-]+)/([0-9.]+)"i, u)
    m === nothing && return "unknown"
    m[2] == "zero" ? "CC0-1.0" : spdx("cc-$(lowercase(m[2]))-$(m[3])")
end

function agent(c)
    a = OrderedDict{String, Any}("name" => c["name"])
    get(c, "nameType", "") == "Organizational" && (a["kind"] = occursin(r"collaboration"i, c["name"]) ? "collaboration" : "organization")
    for id in get(c, "nameIdentifiers", [])
        get(id, "nameIdentifierScheme", "") == "ORCID" && (a["orcid"] = last(split(id["nameIdentifier"], '/')))
    end
    aff = get(c, "affiliation", [])
    isempty(aff) || (a["affiliation"] = aff[1] isa AbstractDict ? aff[1]["name"] : string(aff[1]))
    a
end

bare_doi(x) = replace(strip(x), r"^(https?://(dx\.)?doi\.org/|doi:)"i => "")

function from_doi(doi; type = nothing)
    doi = bare_doi(doi)
    from_datacite(getjson("https://api.datacite.org/dois/$(HTTP.escapeuri(doi))")["data"]["attributes"], doi; type)
end

"""
    from_datacite(attributes, doi; type = nothing, enrich = true)

Record skeleton from DataCite `attributes` (as returned by the single-DOI and search APIs). With `enrich`, file lists
(Zenodo) and licences missing from DataCite (Dataverse) are fetched from the repository.
"""
function from_datacite(d, doi; type = nothing, enrich = true)
    title = strip(d["titles"][1]["title"])
    rtype = get(d["types"], "resourceTypeGeneral", "")
    type = something(type, rtype == "Software" ? "software" : rtype == "Collection" ? "collection" : "dataset")
    rights = get(d, "rightsList", [])
    lic = isempty(rights) ? "unknown" : spdx(get(rights[1], "rightsIdentifier", ""))
    lic == "unknown" && !isempty(rights) && (lic = spdx_from_url(get(rights[1], "rightsUri", "")))
    desc = [x["description"] for x in get(d, "descriptions", []) if get(x, "descriptionType", "") == "Abstract"]
    issued = [x["date"] for x in get(d, "dates", []) if x["dateType"] == "Issued"]
    updated = [x["date"] for x in get(d, "dates", []) if x["dateType"] == "Updated"]
    rec = OrderedDict{String, Any}(
        "id" => slug(title), "type" => type, "title" => title, "short" => first(title, 120),
        "description" => isempty(desc) ? "TODO" : striphtml(desc[1]),
        "doi" => doi, "url_landing" => d["url"],
        "creators" => agent.(d["creators"]),
        "publisher" => OrderedDict("name" => d["publisher"] isa AbstractDict ? d["publisher"]["name"] : d["publisher"]),
        "version" => something(get(d, "version", nothing), ""),
        "date_published" => isempty(issued) ? d["publicationYear"] : issued[1][1:min(end, 10)],
        "license" => lic)
    isempty(updated) || (rec["date_updated"] = updated[1][1:10])
    isempty(rights) || !startswith(get(rights[1], "rightsUri", ""), "http") || (rec["license_url"] = rights[1]["rightsUri"])
    rec["version"] == "" && delete!(rec, "version")
    rec["access"] = "open"
    host = startswith(doi, "10.5281/zenodo") ? "zenodo" : startswith(doi, "10.7910/DVN") ? "dataverse" :
           startswith(doi, "10.17182/hepdata") ? "hepdata" : "institutional"
    dist = OrderedDict{String, Any}("url" => "https://doi.org/$doi", "host" => host, "role" => "primary")
    if enrich && host == "zenodo"
        z = tryjson("https://zenodo.org/api/records/$(split(doi, '.')[end])")
        if z !== nothing
            files = get(z, "files", [])
            dist["formats"] = unique(guess_format.([f["key"] for f in files]))
            dist["size_bytes"] = sum(f -> f["size"], files; init = 0)
            dist["n_files"] = length(files)
            dist["notes"] = "files: " * join([f["key"] for f in files], ", ")
            haskey(z, "conceptdoi") && z["conceptdoi"] != doi && (rec["versions"] = [OrderedDict("version" => get(rec, "version", "?"), "doi" => doi)];
                                                                 rec["identifiers"] = OrderedDict("zenodo" => z["id"]))
        end
    end
    if enrich && host == "dataverse" && rec["license"] == "unknown"   # Dataverse licences are often missing in DataCite
        dv = tryjson("https://dataverse.harvard.edu/api/datasets/:persistentId/?persistentId=doi:$doi")
        l = dv === nothing ? nothing : get(get(dv["data"], "latestVersion", Dict()), "license", nothing)
        l isa AbstractDict && (rec["license"] = spdx(get(l, "rightsIdentifier", "")); rec["license_url"] = l["uri"])
    end
    rec["distributions"] = [dist]
    refs = [OrderedDict{String, Any}("doi" => bare_doi(r["relatedIdentifier"]), "relation" => "describes")
            for r in get(d, "relatedIdentifiers", []) if r["relatedIdentifierType"] == "DOI" && r["relationType"] in ("IsSupplementTo", "IsDocumentedBy", "IsDescribedBy")]
    append!(refs, [OrderedDict{String, Any}("arxiv" => replace(r["relatedIdentifier"], r"^arXiv:"i => ""), "relation" => "describes")
                   for r in get(d, "relatedIdentifiers", []) if r["relatedIdentifierType"] == "arXiv"])
    isempty(refs) || (rec["references"] = refs)
    rec
end

function from_github(url)
    m = match(r"github\.com/([^/]+)/([^/#?]+)", url)
    from_github_repo(getjson("https://api.github.com/repos/$(m[1])/$(replace(m[2], r"\.git$" => ""))"))
end

"Record skeleton from a GitHub API repository object (single-repo or search result)"
function from_github_repo(repo)
    lic = repo["license"] === nothing ? "none-stated" : spdx(repo["license"]["spdx_id"])
    rec = OrderedDict{String, Any}(
        "id" => slug(repo["name"]), "type" => "software", "title" => repo["name"],
        "short" => first(something(repo["description"], repo["name"]), 120),
        "description" => something(repo["description"], "TODO"),
        "url_landing" => isempty(something(repo["homepage"], "")) ? repo["html_url"] : repo["homepage"],
        "owner" => OrderedDict("name" => repo["owner"]["login"], "kind" => repo["owner"]["type"] == "Organization" ? "organization" : "person"),
        "date_published" => repo["created_at"][1:10], "date_updated" => repo["pushed_at"][1:10],
        "license" => lic, "access" => "open",
        "distributions" => [OrderedDict("url" => repo["html_url"], "host" => "github", "role" => "primary", "formats" => ["source-code"])],
        "software" => OrderedDict("repository" => repo["html_url"], "languages" => filter(!isnothing, [repo["language"]]),
                                  "purposes" => ["tooling"], "development_status" => repo["archived"] ? "archived" : "unknown"))
    rec
end

function scaffold(arg; id = nothing, type = nothing)
    rec = occursin("github.com", arg) ? from_github(arg) : from_doi(arg; type)
    id === nothing || (rec["id"] = id)
    rec["type"] in ("dataset", "result") && (rec["data"] = OrderedDict("levels" => ["binned"]))
    rec["type"] == "model" && (rec["model"] = OrderedDict("quantities" => ["TODO"]))
    for k in ("experiments", "sources", "topics"); rec[k] = String[]; end
    rec["curation"] = OrderedDict("status" => "candidate", "added" => today(), "source" => "new_record.jl $arg")
    rec
end

function main(args)
    opts = Dict(m[1] => m[2] for m in (match(r"^--([a-z]+)=(.*)$", a) for a in args) if m !== nothing)
    targets = filter(a -> !startswith(a, "--"), args)
    for t in targets
        rec = try
            scaffold(t; id = get(opts, "id", nothing), type = get(opts, "type", nothing))
        catch e
            println(stderr, "skipped $t: ", sprint(showerror, e)[1:min(end, 200)])
            continue
        end
        txt = "# scaffolded by tools/new_record.jl on $(today()); review every field\n" * to_yaml(rec)
        if "--write" in args
            path = joinpath(ROOT, "candidates", rec["type"], rec["id"] * ".yaml")
            mkpath(dirname(path)); write(path, txt); println("wrote ", relpath(path, ROOT))
        else
            print(txt)
        end
    end
end

abspath(PROGRAM_FILE) == (@__FILE__) && main(ARGS)
