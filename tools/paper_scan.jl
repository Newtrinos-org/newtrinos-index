#!/usr/bin/env julia
# Find data releases that accompany neutrino papers: links stored by INSPIRE, links in arXiv comments/abstracts,
# arXiv ancillary files, and links inside the full text (ar5iv HTML). Stages are cached and resumable.
#   julia --project tools/paper_scan.jl papers      paper list from INSPIRE (collaboration papers of all registry
#                                                   experiments + neutrino papers with >= 20 citations)
#   julia --project tools/paper_scan.jl comments    arXiv API (100 ids / request): URLs in comments and abstracts
#   julia --project tools/paper_scan.jl anc         arXiv abstract pages: ancillary files (1 request / 3 s)
#   julia --project tools/paper_scan.jl fulltext    ar5iv HTML of collaboration papers: links in the text (1 / 3 s)
#   julia --project tools/paper_scan.jl publisher   Springer / IOP / AAS / Elsevier article pages: supplements, links
#   julia --project tools/paper_scan.jl report      candidates/PAPERS.md + candidates/papers_hits.jsonl
# Cache: .harvest_cache/papers/ (gitignored). Output in candidates/ (local review queue, not published).
include("common.jl")
using HTTP

const CACHE = joinpath(ROOT, ".harvest_cache", "papers"); mkpath(CACHE)
const UA = ["User-Agent" => "newtrinos-index paper scan (https://github.com/Newtrinos-org/newtrinos-index; polite, cached)"]
cpath(kind, id) = joinpath(CACHE, kind, replace(id, "/" => "_") * ".txt")
function fetch_cached(kind, id, url; pause = 3.0)
    f = cpath(kind, id); mkpath(dirname(f))
    isfile(f) && return read(f, String)
    body = try
        r = HTTP.get(url, UA; read_idle_timeout = 120, retries = 2, status_exception = false)
        r.status == 200 ? String(r.body) : "HTTP $(r.status)"
    catch e
        "ERROR $(sprint(showerror, e)[1:min(end, 100)])"
    end
    startswith(body, "ERROR") || write(f, body)     # do not cache transient network errors
    sleep(pause)
    body
end

# ------------------------------------------------------------------------------------------------ papers
const PAPERS = joinpath(CACHE, "papers.json")
function inspire_all(q; fields = "control_number,arxiv_eprints,dois,titles,citation_count,collaborations,urls,publication_info")
    out = Any[]; page = 1
    while true
        url = "https://inspirehep.net/api/literature?q=$(HTTP.escapeuri(q))&size=250&page=$page&fields=$fields&sort=mostcited"
        r = try JSON.parse(String(HTTP.get(url, UA; read_idle_timeout = 120, retries = 3).body)) catch e; @warn "INSPIRE" q page exception = e; break end
        hits = r["hits"]["hits"]; append!(out, hits)
        (isempty(hits) || length(out) >= r["hits"]["total"] || page * 250 >= 10_000) && break
        page += 1; sleep(1)
    end
    out
end
function stage_papers()
    vocab = load_vocab()
    papers = Dict{String, Any}()
    function add(h, tag)
        m = h["metadata"]; a = get(m, "arxiv_eprints", nothing)
        a === nothing && return
        id = a[1]["value"]
        p = get!(papers, id, Dict{String, Any}("arxiv" => id, "tags" => String[]))
        p["inspire"] = h["id"]; p["title"] = m["titles"][1]["title"]; p["citations"] = get(m, "citation_count", 0)
        p["dois"] = [d["value"] for d in get(m, "dois", [])]
        p["inspire_urls"] = [u["value"] for u in get(m, "urls", [])]
        p["collaborations"] = [c["value"] for c in get(m, "collaborations", [])]
        tag in p["tags"] || push!(p["tags"], tag)
    end
    for e in vocab["experiments"]
        names = unique(filter(n -> length(n) > 2, vcat(get(e, "collaboration", e["name"]), e["name"])))
        q = "(" * join(["cn \"$n\"" for n in names], " or ") * ") and arxiv:*"
        hs = inspire_all(q); foreach(h -> add(h, "collab:" * e["id"]), hs)
        println("  $(rpad(e["id"], 20)) $(length(hs))")
    end
    for (q, tag) in (("k neutrino and topcite 20+ and arxiv:*", "pheno"),)
        hs = inspire_all(q); foreach(h -> add(h, tag), hs); println("  $(rpad(tag, 20)) $(length(hs)) (INSPIRE returns at most 10 000)")
    end
    write(PAPERS, JSON.json(collect(values(papers))))
    println("$(length(papers)) papers → $(relpath(PAPERS, ROOT))")
end
load_papers() = JSON.parsefile(PAPERS)

# ------------------------------------------------------------------------------------------------ URL extraction
const URL_RE = r"(https?://[^\s\"'<>\)\]\}\\,;]+|www\.[a-z0-9.-]+\.[a-z]{2,}[^\s\"'<>\)\]\}\\,;]*|github\.com/[^\s\"'<>\)\]\}\\,;]+|zenodo\.org/[^\s\"'<>\)\]\}\\,;]+)"i
# links that are citations / infrastructure, not resources
const BORING = r"(arxiv\.org/(abs|pdf|licenses|help)|doi\.org/|dx\.doi|inspirehep|inspire-hep|creativecommons|w3\.org|mathjax|ar5iv|arxiv\.org/html|journals\.aps\.org/[a-z]+/abstract|link\.springer|sciencedirect|iopscience|ams\.org|crossref|orcid|scholar\.google|semanticscholar|adsabs|harvard\.edu/abs|cern\.ch/record|indico|youtube|twitter|facebook|wikipedia|latexml|cornell\.edu|simonsfoundation|slac\.stanford\.edu/spires|cds\.cern\.ch/record|pdg\.lbl\.gov/20\d\d/reviews)"i
# preprint servers, document libraries, news and press: never resources
const NOISE = r"(lss\.fnal\.gov|weblib\.cern|slac\.stanford\.edu|cdsweb|iop\.org/EJ|pos\.sissa|interactions\.org|fnal\.gov/pub/today|news\.|/news/|physics\.aps\.org|symmetrymagazine|phys\.org|physicsworld|scientificamerican|nature\.com/articles/d4|livescience|quantamagazine|sciencenews|mathnet|edpsciences|link\.aip|library\.desy|ictp\.|jlab\.org/(Ul|ul)/publications|misportal|th-www\.if\.uj\.edu\.pl/acta|science\.energy\.gov|press|atlas\.web\.cern|cms-results|lhcbproject|cern\.ch/lhcbproject|rivet\.hepforge|proceedings|/econf/|preprint|/papers?/[^/]*\.(pdf|ps)|\.ps(\.gz)?$)"i
# code / data hosts, or paths that look like data
const DATAHOST = r"(github\.com|gitlab|zenodo|hepforge|figshare|dataverse|sourceforge|bitbucket|osf\.io|huggingface|kaggle|data\.mendeley|codeocean|software\.|pypi\.org)"i
const DATAPATH = r"(data|release|download|files|tables?|code|software|results/|public|supplement|anc|\.(txt|dat|csv|zip|tar|gz|root|h5|hdf5|json|npz)$)"i
clean(u) = rstrip(replace(u, r"^www\." => "http://www."), ['.', ':', ')'])
interesting(u) = !occursin(BORING, u) && !occursin(NOISE, u) && length(u) > 14 && (occursin(DATAHOST, u) || occursin(DATAPATH, replace(u, r"^https?://[^/]+" => "")))

# ------------------------------------------------------------------------------------------------ comments
function stage_comments()
    ps = load_papers(); ids = [p["arxiv"] for p in ps]
    for chunk in Iterators.partition(ids, 100)
        key = "batch_" * bytes2hex(sha1(join(chunk, ",")))[1:16]
        fetch_cached("comments", key, "https://export.arxiv.org/api/query?id_list=$(join(chunk, ","))&max_results=100"; pause = 3.0)
    end
    println("comments: $(length(ids)) papers in $(cld(length(ids), 100)) arXiv API requests (cached)")
end
"arxiv id → (comment, abstract) from the cached API batches"
function parse_comments()
    out = Dict{String, Tuple{String, String}}()
    dir = joinpath(CACHE, "comments"); isdir(dir) || return out
    for f in readdir(dir; join = true), e in eachmatch(r"<entry>(.*?)</entry>"s, read(f, String))
        x = e[1]; m = match(r"<id>https?://arxiv\.org/abs/([^<]+?)(v\d+)?</id>", x); m === nothing && continue
        c = match(r"<arxiv:comment[^>]*>(.*?)</arxiv:comment>"s, x); s = match(r"<summary>(.*?)</summary>"s, x)
        out[m[1]] = (c === nothing ? "" : c[1], s === nothing ? "" : s[1])
    end
    out
end

# ------------------------------------------------------------------------------------------------ ancillary files
function stage_anc(; limit = typemax(Int))
    ps = sort(load_papers(), by = p -> -length(p["tags"]) - (any(startswith("collab:"), p["tags"]) ? 100 : 0) - p["citations"] / 1e6)
    n = 0
    for p in ps
        n >= limit && break
        isfile(cpath("abs", p["arxiv"])) && continue
        fetch_cached("abs", p["arxiv"], "https://arxiv.org/abs/$(p["arxiv"])"; pause = 3.0); n += 1
        n % 200 == 0 && println("  anc: $n abstract pages fetched")
    end
    println("anc: $n new abstract pages fetched")
end
anc_files(id) = (f = cpath("abs", id); isfile(f) ? unique([m[1] for m in eachmatch(r"href=\"(/src/[^\"]+/anc/[^\"]+)\"", read(f, String))]) : String[])

# ------------------------------------------------------------------------------------------------ full text
function stage_fulltext(; limit = typemax(Int))
    ps = filter(p -> any(startswith("collab:"), p["tags"]), load_papers()); n = 0
    for p in ps
        n >= limit && break
        isfile(cpath("ar5iv", p["arxiv"])) && continue
        fetch_cached("ar5iv", p["arxiv"], "https://ar5iv.labs.arxiv.org/html/$(p["arxiv"])"; pause = 3.0); n += 1
        n % 200 == 0 && println("  fulltext: $n papers fetched")
    end
    println("fulltext: $n new papers fetched")
end
fulltext_links(id) = (f = cpath("ar5iv", id); isfile(f) ? unique(clean.([m[1] for m in eachmatch(r"href=\"(https?://[^\"#]+)\"", read(f, String))])) : String[])

# ------------------------------------------------------------------------------------------------ publisher pages
# Springer (JHEP, EPJC, …) and IOP / AAS (JCAP, JINST, ApJ) article pages: supplementary files and links in the text
# (e.g. "Data availability" statements). APS and ScienceDirect refuse automated requests from this host.
const PUBLISHER_DOI = r"^10\.(1007|1140|1088|3847|1016)/"
function stage_publisher(; limit = typemax(Int))
    ps = filter(p -> any(d -> occursin(PUBLISHER_DOI, d), get(p, "dois", [])), load_papers()); n = 0
    for p in ps
        n >= limit && break
        doi = first(filter(d -> occursin(PUBLISHER_DOI, d), p["dois"]))
        isfile(cpath("publisher", p["arxiv"])) && continue
        fetch_cached("publisher", p["arxiv"], "https://doi.org/$doi"; pause = 2.0); n += 1
        n % 200 == 0 && println("  publisher: $n pages fetched")
    end
    println("publisher: $n new article pages fetched")
end
function publisher_links(id)
    f = cpath("publisher", id); isfile(f) || return String[]
    h = read(f, String); startswith(h, "HTTP ") && return String[]
    esm = [m[1] for m in eachmatch(r"\"(https?://static-content\.springer\.com/esm/[^\"]+)\"", h)]
    iop = [m[1] for m in eachmatch(r"\"(https?://(?:content\.cld\.iop\.org|iopscience\.iop\.org)/[^\"]*(?:suppdata|/media/)[^\"]*)\"", h)]
    txt = [m[1] for m in eachmatch(r"href=\"(https?://[^\"#]+)\"", h)]
    unique(vcat(esm, iop, clean.(txt)))
end

# ------------------------------------------------------------------------------------------------ report
function stage_report()
    ps = load_papers(); com = parse_comments()
    known = Set{String}()
    for (_, r) in load_records(), u in vcat([d["url"] for d in r["distributions"]], get(r, "url_landing", ""))
        isempty(u) || push!(known, rstrip(lowercase(replace(u, r"^https?://(www\.)?" => "")), '/'))
    end
    isknown(u) = rstrip(lowercase(replace(u, r"^https?://(www\.)?" => "")), '/') in known
    catalogued_arxiv = Set{String}()
    for (_, r) in load_records(), x in get(r, "references", [])
        haskey(x, "arxiv") && push!(catalogued_arxiv, string(x["arxiv"]))
    end
    hits = Any[]
    for p in ps
        id = p["arxiv"]
        links = Dict{String, String}()
        for u in get(p, "inspire_urls", []); interesting(u) && (links[clean(u)] = "inspire"); end
        if haskey(com, id)
            c, s = com[id]
            for m in eachmatch(URL_RE, c); u = clean(m[1]); interesting(u) && (links[u] = "comment"); end
            for m in eachmatch(URL_RE, s); u = clean(m[1]); interesting(u) && (links[u] = "abstract"); end
        end
        for u in fulltext_links(id); interesting(u) && !haskey(links, u) && (links[u] = "fulltext"); end
        for u in publisher_links(id)
            occursin(r"static-content\.springer\.com/esm|suppdata|iop\.org/.*/media/", u) ? (links[u] = "publisher-supplement") :
                (interesting(u) && !occursin(r"springer|nature\.com|iop\.org|elsevier|sciencedirect|aas\.org", u) && !haskey(links, u) && (links[u] = "publisher-page"))
        end
        anc = anc_files(id)
        isempty(anc) && isempty(links) && continue
        push!(hits, Dict("arxiv" => id, "title" => p["title"], "citations" => p["citations"], "tags" => p["tags"],
                         "anc" => anc, "links" => [Dict("url" => u, "where" => w, "known" => isknown(u)) for (u, w) in links],
                         "paper_catalogued" => id in catalogued_arxiv))
    end
    open(joinpath(ROOT, "candidates", "papers_hits.jsonl"), "w") do io
        foreach(h -> println(io, JSON.json(h)), hits)
    end
    n_anc = count(h -> !isempty(h["anc"]) && !h["paper_catalogued"], hits)
    n_links = count(h -> any(l -> !l["known"], h["links"]), hits)
    open(joinpath(ROOT, "candidates", "PAPERS.md"), "w") do io
        println(io, "# Resources accompanying papers ($(Dates.today()))\n\n$(length(ps)) papers scanned; $(length(hits)) with ancillary files or links; ",
                "$n_anc with ancillary files whose paper is not yet referenced by a record; $n_links with links not yet catalogued.\n")
        println(io, "| arXiv | cites | ancillary files | new links (where) | title |\n|---|---:|---|---|---|")
        for h in sort(hits, by = h -> -h["citations"])
            newl = [l for l in h["links"] if !l["known"]]
            (isempty(newl) && (isempty(h["anc"]) || h["paper_catalogued"])) && continue
            anc = isempty(h["anc"]) ? "" : "$(length(h["anc"])): " * join(first.(splitext.(basename.(h["anc"]))), ", ")[1:min(end, 120)]
            println(io, "| [$(h["arxiv"])](https://arxiv.org/abs/$(h["arxiv"])) | $(h["citations"]) | $anc | ",
                    join(["$(l["url"]) ($(l["where"]))" for l in newl[1:min(end, 6)]], "<br>"), " | $(replace(first(h["title"], 90), "|" => "/")) |")
        end
    end
    println("report: $(length(hits)) papers with resources; $n_anc new ancillary sets; $n_links papers with new links → candidates/PAPERS.md")
end

using SHA
function main(args)
    stage = isempty(args) ? "report" : args[1]
    lim = something(tryparse(Int, get(args, 2, "")), typemax(Int))
    stage == "papers" ? stage_papers() : stage == "comments" ? stage_comments() : stage == "anc" ? stage_anc(; limit = lim) :
    stage == "fulltext" ? stage_fulltext(; limit = lim) : stage == "publisher" ? stage_publisher(; limit = lim) : stage_report()
end
abspath(PROGRAM_FILE) == (@__FILE__) && main(ARGS)
