#!/usr/bin/env julia
# List data files of collaboration / group web sites as archived by the Internet Archive (Wayback CDX index), grouped by
# directory, and mark what the catalogue already links to. For sites that are offline (moved, shut down, security
# incidents) this is often the only way to find their releases.
#   julia --project tools/archive_scan.jl [label-substring ...]      sites from tools/harvest/archives.toml
# Writes candidates/ARCHIVES.md (review list; candidates/ is not published) and prints a summary.
include("common.jl")
using HTTP, TOML

const SITES = TOML.parsefile(joinpath(@__DIR__, "harvest", "archives.toml"))["site"]
const DATA_EXT = r"\.(txt|dat|csv|tsv|root|zip|tar|gz|tgz|bz2|xz|h5|hdf5|npz|npy|json|ya?ml|tab|out|f|for|c|cc|cpp|py|nb|m|xls|xlsx|fits)$"i
const NOT_DATA = r"\.(ps\.gz|pdf\.gz)$|/(wp-includes|wp-admin|wp-json|modules|themes|misc|includes|cgi-bin)/|robots\.txt$|LICENSE\.txt$|INSTALL|CHANGELOG|COPYRIGHT|MAINTAINERS|UPGRADE|README\.txt$"i

"Archived 200-status URLs under a prefix (one row per URL: original, timestamp of the latest capture, length)"
function cdx(prefix)
    url = "https://web.archive.org/cdx/search/cdx?url=" * HTTP.escapeuri(prefix * "*") *
          "&output=json&fl=original,timestamp,length&filter=statuscode:200&collapse=urlkey&limit=20000"
    for attempt in 1:3
        try
            r = HTTP.get(url; read_idle_timeout = 180, retries = 1, status_exception = false)
            r.status == 200 && return [x for x in JSON.parse(String(r.body))[2:end]]
            r.status in (429, 503) && (sleep(20 * attempt); continue)
            return []
        catch e
            @warn "CDX failed" prefix attempt exception = e
            sleep(10 * attempt)
        end
    end
    []
end

normurl(u) = rstrip(lowercase(replace(replace(u, r":80/" => "/"), r"^https?://(www\.)?" => "")), '/')

"Every URL the catalogue links to (normalised), and their directories"
function catalogue_urls()
    urls = Set{String}()
    for (_, r) in load_records(), u in vcat([d["url"] for d in r["distributions"]], get(r, "url_landing", ""))
        isempty(u) && continue
        u = replace(u, r"^https?://web\.archive\.org/web/[0-9*]+/" => "")
        push!(urls, normurl(u))
    end
    urls
end
known(u, urls) = (n = normurl(u); n in urls || any(k -> length(k) > 12 && (startswith(n, k * "/") || startswith(k, n)), urls))

function main(args)
    sites = isempty(args) ? SITES : filter(s -> any(a -> occursin(lowercase(a), lowercase(s["label"])), args), SITES)
    urls = catalogue_urls()
    report = String["# Archived data files of collaboration and group sites ($(Dates.today()))\n",
        "From the Internet Archive CDX index. **known** = the catalogue links to this file or its directory. ",
        "Wayback links: `https://web.archive.org/web/<timestamp>/<url>`.\n"]
    total = 0; new = 0
    for s in sites
        rows = Any[]
        for p in s["prefix"]
            append!(rows, cdx(p)); sleep(2)
        end
        files = unique(r -> normurl(r[1]), filter(r -> occursin(DATA_EXT, r[1]) && !occursin(NOT_DATA, r[1]), rows))
        groups = Dict{String, Vector{Any}}()
        for f in files
            dir = replace(f[1], r"/[^/]*$" => "/")
            push!(get!(groups, dir, Any[]), f)
        end
        nnew = count(f -> !known(f[1], urls), files)
        total += length(files); new += nnew
        println(rpad(s["label"], 28), lpad(length(rows), 6), " archived URLs  ", lpad(length(files), 5), " data files  ", lpad(nnew, 5), " not in the catalogue")
        isempty(files) && continue
        push!(report, "\n## $(s["label"]) — $(length(files)) data files in $(length(groups)) directories, $nnew not linked by the catalogue\n")
        for dir in sort(collect(keys(groups)))
            fs = groups[dir]
            k = all(f -> known(f[1], urls), fs) ? " **known**" : ""
            size = sum(f -> something(tryparse(Int, f[3]), 0), fs)
            latest = maximum(f -> f[2], fs)
            push!(report, "- [`$(dir)`](https://web.archive.org/web/$(latest)/$(dir)) — $(length(fs)) files, ~$(round(size / 1e6, digits = 1)) MB compressed, latest capture $(latest[1:8])$k")
            for f in sort(fs, by = first)[1:min(end, 12)]
                push!(report, "  - [$(replace(f[1], dir => ""))](https://web.archive.org/web/$(f[2])/$(f[1]))$(known(f[1], urls) ? " (known)" : "")")
            end
            length(fs) > 12 && push!(report, "  - … $(length(fs) - 12) more")
        end
    end
    mkpath(joinpath(ROOT, "candidates"))
    write(joinpath(ROOT, "candidates", "ARCHIVES.md"), join(report, "\n") * "\n")
    println("\n$total archived data files, $new not linked by the catalogue → candidates/ARCHIVES.md")
end

abspath(PROGRAM_FILE) == (@__FILE__) && main(ARGS)
