#!/usr/bin/env julia
# Build the static site: records/**/*.yaml + vocab/*.yaml (+ status/*.json) → public/
#   julia --project site/build.jl [--out=public]
include(joinpath(dirname(@__DIR__), "tools", "common.jl"))
using Markdown

const OUT = let o = filter(a -> startswith(a, "--out="), ARGS)
    isempty(o) ? joinpath(ROOT, "public") : abspath(o[1][7:end])
end
const SITE = (name = "Newtrinos Index",
              tagline = "A curated catalogue of neutrino data sets, codes, models and results",
              repo = "https://github.com/Newtrinos-org/newtrinos-index")

# ------------------------------------------------------------------------------------------------
# helpers
# ------------------------------------------------------------------------------------------------
esc(s) = replace(string(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "\"" => "&quot;")
md(s) = Markdown.html(Markdown.parse(string(s)))                 # Markdown → HTML (descriptions, card text)
tag(text; cls = "") = """<span class="tag $cls">$(esc(text))</span>"""
doi_link(d) = """<a href="https://doi.org/$(esc(d))">doi:$(esc(d))</a>"""
function bytes_str(n)
    n < 1024 ? "$n B" : n < 1024^2 ? "$(round(n / 1024, digits = 1)) kB" : n < 1024^3 ? "$(round(n / 1024^2, digits = 1)) MB" : "$(round(n / 1024^3, digits = 2)) GB"
end
"Link targets in relations / cite_as: record id, doi:..., or URL"
function target_html(t, byid; r = "")
    haskey(byid, t) && return """<a href="$(r)records/$(esc(t))/">$(esc(byid[t]["title"]))</a>"""
    startswith(t, "doi:") && return doi_link(t[5:end])
    startswith(t, "http") && return """<a href="$(esc(t))">$(esc(t))</a>"""
    esc(t)
end

const TYPE_INFO = [
    ("dataset", "Data sets", "Experiment data releases: event lists, spectra, responses, MC samples, figure data."),
    ("result", "Results", "Likelihoods, Δχ² maps, posterior samples, contours and global-fit tables."),
    ("model", "Models & inputs", "Fluxes, cross-section tables, solar and Earth models."),
    ("software", "Software", "Oscillation calculators, event generators, fitters, flux codes."),
    ("service", "Services", "Databases and portals: HEPData, PDG, reactor databases."),
    ("collection", "Collections", "Groups of related resources, such as a collaboration's open-data pages."),
]
type_label(t) = TYPE_INFO[findfirst(x -> x[1] == t, TYPE_INFO)][2]
const STATUS_LABEL = Dict("candidate" => "Candidate", "curated" => "Curated", "verified" => "Verified")
const ACCESS_LABEL = Dict("open" => "Open", "registration" => "Registration", "on-request" => "On request",
                          "collaboration-only" => "Collaboration only", "defunct" => "Defunct")
const INVERSE = Dict("is_part_of" => "has_part", "has_part" => "is_part_of", "supersedes" => "superseded_by",
                     "superseded_by" => "supersedes", "derived_from" => "source_of", "source_of" => "derived_from",
                     "uses" => "used_by", "used_by" => "uses", "mirror_of" => "mirror_of", "compares_with" => "compares_with",
                     "documents" => "is_documented_by", "reproduces" => "is_reproduced_by", "is_version_of" => "has_version")
rel_label(r) = replace(r, "_" => " ")
const CARD_SECTIONS = [("summary", "Summary"), ("intended_use", "Intended use"), ("out_of_scope_use", "Out-of-scope use"),
    ("provenance", "Provenance"), ("composition", "Composition"), ("systematics", "Systematics"),
    ("physics_assumptions", "Physics assumptions"), ("validation", "Validation"), ("known_limitations", "Known limitations"),
    ("maintenance", "Maintenance"), ("usage_examples", "Usage")]
card_score(rec) = count(s -> !isempty(strip(string(get(get(rec, "card", Dict()), s[1], "")))), CARD_SECTIONS)

# ------------------------------------------------------------------------------------------------
# page frame (shared look with newtrinos-verifications)
# ------------------------------------------------------------------------------------------------
function page(title, body; depth = 0, description = SITE.tagline, active = "", head = "")
    r = depth == 0 ? "./" : "../"^depth
    nav(href, label, key) = """<a href="$r$href"$(active == key ? " class=\"active\"" : "")>$label</a>"""
    """
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$(esc(title))</title>
<meta name="description" content="$(esc(description))">
<link rel="icon" type="image/svg+xml" href="$(r)assets/logo.svg">
<link rel="stylesheet" href="$(r)assets/style.css">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Newsreader:opsz,wght@6..72,500;6..72,600&family=Public+Sans:wght@400;500;600&family=JetBrains+Mono:wght@400;500&display=swap">
$head</head>
<body data-root="$r">
<header class="site-header">
  <div class="wrap header-inner">
    <span class="brand"><a href="https://newtrinos-org.github.io/" title="Newtrinos home"><picture><source srcset="$(r)assets/logo-dark.svg" media="(prefers-color-scheme: dark)"><img class="brand-logo" src="$(r)assets/logo.svg" alt="Newtrinos home" width="32" height="32"></picture></a> <a href="$r">$(SITE.name)</a></span>
    <nav class="main-nav">
      $(nav("records/", "Browse", "records"))
      $(nav("experiments/", "Experiments", "experiments"))
      $(nav("about/", "Schema & about", "about"))
    </nav>
  </div>
</header>
<main class="wrap">
$body
</main>
<footer class="site-footer">
  <div class="wrap">
    Part of <a href="https://newtrinos-org.github.io/">Newtrinos</a> ·
    <a href="https://github.com/Newtrinos-org/Newtrinos.jl">Newtrinos.jl</a> ·
    <a href="https://newtrinos-org.github.io/newtrinos-verifications/">verifications</a> ·
    <a href="$(SITE.repo)">source</a> · generated $(Dates.format(now(UTC), "yyyy-mm-dd"))<br>
    Catalogue metadata: <a href="https://creativecommons.org/publicdomain/zero/1.0/">CC0</a> · code: <a href="$(SITE.repo)/blob/main/LICENSE">MIT</a> ·
    the catalogued resources keep their own licences · exports: <a href="$(r)index.json">JSON</a>, <a href="$(r)catalog.jsonld">JSON-LD</a>, <a href="$(r)catalog.csv">CSV</a>
  </div>
</footer>
<script src="$(r)assets/app.js"></script>
</body>
</html>
"""
end

# ------------------------------------------------------------------------------------------------
# data
# ------------------------------------------------------------------------------------------------
"Generated facts (link checks, harvested commit dates) from status/<id>.json, if present"
load_status() = Dict(splitext(f)[1] => JSON.parsefile(joinpath(ROOT, "status", f))
                     for f in (isdir(joinpath(ROOT, "status")) ? readdir(joinpath(ROOT, "status")) : String[]) if endswith(f, ".json"))

"All relations of every record, including derived inverses: id → [(rel, target, notes)]"
function all_relations(records)
    out = Dict(rec["id"] => Tuple{String, String, String}[] for rec in records)
    for rec in records, x in get(rec, "relations", [])
        push!(out[rec["id"]], (x["rel"], x["target"], get(x, "notes", "")))
        t = x["target"]
        haskey(out, t) && haskey(INVERSE, x["rel"]) && push!(out[t], (INVERSE[x["rel"]], rec["id"], get(x, "notes", "")))
    end
    Dict(k => unique(v) for (k, v) in out)
end

vlabel(vocab, name, id) = (i = findfirst(e -> e["id"] == id, vocab[name]); i === nothing ? id : vocab[name][i]["label"])
exp_name(vocab, id) = (i = findfirst(e -> e["id"] == id, vocab["experiments"]); i === nothing ? id : vocab["experiments"][i]["name"])
det_name(vocab, id) = (i = findfirst(e -> e["id"] == id, vocab["detectors"]); i === nothing ? id : vocab["detectors"][i]["label"])

function index_record(rec, vocab, rels)
    data = get(rec, "data", Dict())
    Dict("id" => rec["id"], "type" => rec["type"], "type_label" => type_label(rec["type"]),
         "title" => rec["title"], "short" => rec["short"], "doi" => get(rec, "doi", ""),
         "year" => string(get(rec, "date_published", ""))[1:min(end, 4)],
         "experiments" => [exp_name(vocab, e) for e in get(rec, "experiments", [])],
         "detectors" => [det_name(vocab, d) for d in get(rec, "detectors", [])],
         "sources" => [vlabel(vocab, "sources", s) for s in get(rec, "sources", [])],
         "topics" => [vlabel(vocab, "topics", s) for s in get(rec, "topics", [])],
         "levels" => [vlabel(vocab, "data_levels", s) for s in get(data, "levels", [])],
         "license" => rec["license"], "access" => ACCESS_LABEL[rec["access"]],
         "status" => rec["curation"]["status"], "added" => string(rec["curation"]["added"]),
         "newtrinos" => haskey(rec, "newtrinos") ? "Used by Newtrinos" : "",
         "card" => card_score(rec), "users" => n_users(rec, rels), "keywords" => join(vcat(get(rec, "keywords", []), get(rec, "aliases", [])), " "))
end

# ------------------------------------------------------------------------------------------------
# JSON-LD (schema.org) for search engines and the catalog export
# ------------------------------------------------------------------------------------------------
const SCHEMA_TYPE = Dict("dataset" => "Dataset", "result" => "Dataset", "model" => "Dataset",
                         "software" => "SoftwareSourceCode", "service" => "WebSite", "collection" => "Collection")
function jsonld(rec, vocab)
    agent(a) = Dict("@type" => get(a, "kind", "person") == "person" ? "Person" : "Organization", "name" => a["name"])
    j = Dict{String, Any}("@context" => "https://schema.org", "@type" => SCHEMA_TYPE[rec["type"]],
        "@id" => "https://newtrinos-org.github.io/newtrinos-index/records/$(rec["id"])/",
        "name" => rec["title"], "description" => rec["short"] * "\n\n" * rec["description"],
        "url" => get(rec, "url_landing", rec["distributions"][1]["url"]),
        "keywords" => vcat(get(rec, "keywords", []), [vlabel(vocab, "topics", t) for t in get(rec, "topics", [])],
                           [vlabel(vocab, "sources", s) * " neutrinos" for s in get(rec, "sources", []) if s != "none"], ["neutrino"]),
        "isAccessibleForFree" => rec["access"] == "open")
    haskey(rec, "doi") && (j["identifier"] = "https://doi.org/$(rec["doi"])")
    haskey(rec, "creators") && (j["creator"] = agent.(rec["creators"]))
    haskey(rec, "publisher") && (j["publisher"] = agent(rec["publisher"]))
    haskey(rec, "version") && (j["version"] = rec["version"])
    haskey(rec, "date_published") && (j["datePublished"] = string(rec["date_published"]))
    haskey(rec, "date_updated") && (j["dateModified"] = string(rec["date_updated"]))
    lic = rec["license"]
    lic in ("unknown", "none-stated", "proprietary") || (j["license"] = "https://spdx.org/licenses/$lic.html")
    if rec["type"] in ("dataset", "result", "model")
        j["distribution"] = [Dict("@type" => "DataDownload", "contentUrl" => d["url"],
                                  "encodingFormat" => join(get(d, "formats", []), ", ")) for d in rec["distributions"]]
    elseif rec["type"] == "software"
        sw = rec["software"]
        haskey(sw, "repository") && (j["codeRepository"] = sw["repository"])
        haskey(sw, "languages") && (j["programmingLanguage"] = sw["languages"])
    end
    j
end

# ------------------------------------------------------------------------------------------------
# pages
# ------------------------------------------------------------------------------------------------
function record_card(rec, vocab; r = "")
    tags = join(vcat([tag(type_label(rec["type"]); cls = "cat")],
                     [tag(exp_name(vocab, e); cls = "exp") for e in get(rec, "experiments", [])],
                     [tag(det_name(vocab, d); cls = "exp") for d in get(rec, "detectors", [])],
                     [tag(vlabel(vocab, "sources", s)) for s in get(rec, "sources", []) if s != "none"],
                     [tag(STATUS_LABEL[rec["curation"]["status"]]; cls = "status-$(rec["curation"]["status"])")]), " ")
    """
<article class="card">
  <a class="card-link" href="$(r)records/$(rec["id"])/">
    <h3>$(esc(rec["title"]))</h3>
    <p class="muted">$(esc(rec["short"]))</p>
  </a>
  <div class="tags">$tags</div>
</article>"""
end

function home_page(records, vocab)
    nexp = length(unique(e for rec in records for e in get(rec, "experiments", [])))
    ncodes = count(r -> r["type"] == "software", records)
    tiles = join(["""<a class="cat-tile" href="records/?type=$(esc(label))"><h3>$(esc(label))</h3><p>$(esc(desc))</p>
<span class="muted small">$(count(r -> r["type"] == t, records)) records</span></a>""" for (t, label, desc) in TYPE_INFO], "\n")
    srcs = sort(unique(s for rec in records for s in get(rec, "sources", []) if s != "none"))
    srctiles = join(["""<a class="exp-tile" href="records/?source=$(esc(vlabel(vocab, "sources", s)))">$(esc(vlabel(vocab, "sources", s))) <b>$(count(r -> s in get(r, "sources", []), records))</b></a>""" for s in srcs], "\n")
    recent = join(record_card.(sort(records, by = r -> string(r["curation"]["added"]), rev = true)[1:min(end, 6)], Ref(vocab)), "\n")
    body = """
<section class="hero">
  <h1>$(SITE.name)</h1>
  <p>$(SITE.tagline). Every record says what a resource is, where to get it (including mirrors and archive copies),
  who maintains it, under which licence, and, for curated records, a <i>data card</i>: intended use, provenance,
  validation and known limitations.</p>
  <form class="toolbar" action="records/" method="get"><input type="search" name="q" placeholder="Search data sets, codes, experiments…" aria-label="Search"></form>
  <div class="stats">
    <div><b>$(length(records))</b><span>records</span></div>
    <div><b>$nexp</b><span>experiments</span></div>
    <div><b>$ncodes</b><span>codes</span></div>
    <div><b>$(count(r -> r["curation"]["status"] == "verified", records))</b><span>verified</span></div>
  </div>
</section>
<section><h2>Browse by kind</h2><div class="cat-grid">$tiles</div></section>
<section><h2>Browse by neutrino source</h2><div class="exp-grid">$srctiles</div></section>
<section><h2>Recently added</h2><div class="cards">$recent</div><p><a href="records/">All records →</a></p></section>
<section class="tool">
  <h2>Contribute</h2>
  <p>Records are YAML files in <a href="$(SITE.repo)">$(replace(SITE.repo, "https://github.com/" => ""))</a>, checked against a
  <a href="schema/record.schema.json">JSON Schema</a>. Missing a resource or found an error? Open an issue or a pull request.</p>
  <div class="links"><a class="btn" href="$(SITE.repo)/issues/new?title=Suggest%20a%20resource">Suggest a resource</a>
  <a class="btn" href="about/">How records are described</a></div>
</section>"""
    page(SITE.name, body)
end

function records_page(records, vocab)
    body = """
<h1>Browse</h1>
<div class="browse">
  <aside class="facets" id="facets"><p class="muted">Loading…</p></aside>
  <section>
    <div class="toolbar">
      <input id="search" type="search" placeholder="Search title, DOI, experiment, keyword…" aria-label="Search">
      <select id="sort" aria-label="Sort">
        <option value="title">Title A–Z</option>
        <option value="added">Recently added</option>
        <option value="newest">Newest first</option>
        <option value="card">Best documented</option>
        <option value="users">Most used</option>
      </select>
    </div>
    <p class="muted" id="count"></p>
    <div class="cards" id="list">
      $(join(record_card.(records, Ref(vocab); r = "../"), "\n"))
    </div>
  </section>
</div>"""
    page("Browse · $(SITE.name)", body; depth = 1, active = "records")
end

function kv(rows)
    rows = filter(x -> !isempty(x[2]), rows)
    "<table class=\"kv\">" * join(["<tr><th>$(esc(k))</th><td>$v</td></tr>" for (k, v) in rows]) * "</table>"
end
agent_html(a) = esc(a["name"]) * (haskey(a, "orcid") ? """ <a href="https://orcid.org/$(a["orcid"])">ORCID</a>""" : "") *
                (haskey(a, "affiliation") ? " <span class=\"muted\">($(esc(a["affiliation"])))</span>" : "") *
                (haskey(a, "contact") ? " · <span class=\"muted\">$(esc(a["contact"]))</span>" : "")

"Usage links in one direction: catalogue relations (incl. derived inverses) + external `uses` / `used_by` entries"
function usage(rec, rels, key)
    out = [(kind = "record", target = t, label = "", notes = n) for (rl, t, n) in rels if rl == key]
    append!(out, [(kind = x["kind"], target = x["target"], label = get(x, "label", ""), notes = get(x, "notes", "")) for x in get(rec, key, [])])
    out
end
n_users(rec, rels) = (nt = haskey(rec, "newtrinos") && rec["id"] != "newtrinos-jl"; count(u -> !(nt && u.target == "newtrinos-jl"), usage(rec, rels, "used_by")) + nt)

const VERIF = "https://newtrinos-org.github.io/newtrinos-verifications/entries/"
function usage_item(u, byid; r = "")
    kind = u.kind == "record" ? type_label(byid[u.target]["type"]) : uppercasefirst(replace(u.kind, "-" => " "))
    text = isempty(u.label) ? u.target : u.label
    link = haskey(byid, u.target) ? target_html(u.target, byid; r) :
           startswith(lowercase(u.target), "arxiv:") ? """<a href="https://arxiv.org/abs/$(esc(u.target[7:end]))">$(esc(text))</a>""" :
           startswith(u.target, "doi:") ? """<a href="https://doi.org/$(esc(u.target[5:end]))">$(esc(text))</a>""" :
           """<a href="$(esc(u.target))">$(esc(text))</a>"""
    "<li>$(tag(kind)) $link$(isempty(u.notes) ? "" : " <span class=\"muted\">— $(esc(u.notes))</span>")</li>"
end

function usage_html(rec, rels, byid; r = "")
    uses = [usage_item(u, byid; r) for u in usage(rec, rels, "uses")]
    users = String[]
    nt = get(rec, "newtrinos", Dict())
    if !isempty(nt) && rec["id"] != "newtrinos-jl"
        parts = String[]
        isempty(get(nt, "modules", [])) || push!(parts, "modules " * join(["<code>$(esc(m))</code>" for m in nt["modules"]], ", "))
        isempty(get(nt, "verifications", [])) || push!(parts, "verified in " * join(["""<a href="$(VERIF)$(esc(v))/">$(esc(v))</a>""" for v in nt["verifications"]], ", "))
        haskey(nt, "notes") && push!(parts, "<span class=\"muted\">$(esc(nt["notes"]))</span>")
        push!(users, """<li>$(tag("Newtrinos"; cls = "cat")) <a href="$(r)records/newtrinos-jl/">Newtrinos.jl</a>$(isempty(parts) ? "" : " — " * join(parts, "; "))</li>""")
    end
    # Newtrinos.jl's own `uses` relations duplicate the `newtrinos` block shown above
    append!(users, [usage_item(u, byid; r) for u in usage(rec, rels, "used_by") if !(!isempty(users) && u.target == "newtrinos-jl")])
    out = ""
    isempty(uses) || (out *= """<h2>Uses</h2><ul class="usedby">$(join(uses, "\n"))</ul>\n""")
    isempty(users) || (out *= """<h2>Used by</h2><ul class="usedby">$(join(users, "\n"))</ul>\n""")
    out * """<p class="muted small">Know of another paper or code that uses this, or an input it depends on? <a href="$(SITE.repo)/issues/new?title=$(HTTP_escape("Uses / used by for $(rec["id"]): "))">Tell us</a>.</p>"""
end

function record_page(rec, vocab, byid, rels, status)
    id = rec["id"]
    r = "../../"
    st = get(status, id, Dict())
    linkstat = get(st, "links", Dict())
    badge(url) = haskey(linkstat, url) ? (linkstat[url]["ok"] ? """ <span class="tag status-verified" title="checked $(esc(get(st, "checked", "")))">reachable</span>""" :
                                                                  """ <span class="tag status-candidate" title="checked $(esc(get(st, "checked", "")))">unreachable ($(esc(linkstat[url]["code"])))</span>""") : ""
    tags = join(vcat([tag(type_label(rec["type"]); cls = "cat")],
                     [tag(exp_name(vocab, e); cls = "exp") for e in get(rec, "experiments", [])],
                     [tag(det_name(vocab, d); cls = "exp") for d in get(rec, "detectors", [])],
                     [tag(vlabel(vocab, "sources", s)) for s in get(rec, "sources", []) if s != "none"],
                     [tag(vlabel(vocab, "topics", t); cls = "param") for t in get(rec, "topics", [])],
                     [tag(STATUS_LABEL[rec["curation"]["status"]]; cls = "status-$(rec["curation"]["status"])")]), " ")
    ids = get(rec, "identifiers", Dict())
    buttons = join(filter(!isempty, [
        haskey(rec, "url_landing") ? """<a class="btn" href="$(esc(rec["url_landing"]))">Landing page</a>""" : "",
        haskey(rec, "doi") ? """<a class="btn" href="https://doi.org/$(esc(rec["doi"]))">DOI</a>""" : "",
        haskey(ids, "arxiv") ? """<a class="btn" href="https://arxiv.org/abs/$(esc(ids["arxiv"]))">arXiv</a>""" : "",
        haskey(ids, "inspire") ? """<a class="btn" href="https://inspirehep.net/literature/$(ids["inspire"])">INSPIRE</a>""" : "",
        haskey(rec, "software") && haskey(rec["software"], "repository") ? """<a class="btn" href="$(esc(rec["software"]["repository"]))">Repository</a>""" : "",
        haskey(rec, "software") && haskey(rec["software"], "documentation") ? """<a class="btn" href="$(esc(rec["software"]["documentation"]))">Documentation</a>""" : "",
    ]), " ")

    card = get(rec, "card", Dict())
    cardhtml = if isempty(card)
        ""
    else
        rows = [(label, md(card[k])) for (k, label) in CARD_SECTIONS if haskey(card, k)]
        DPHEP_LABEL = Dict(1 => "publication-level", 2 => "simplified data", 3 => "analysis-level", 4 => "full reconstruction and simulation")
        haskey(card, "dphep_level") &&
            push!(rows, ("Preservation", """DPHEP level $(card["dphep_level"]) <span class="muted">($(DPHEP_LABEL[card["dphep_level"]]))</span>"""))
        if haskey(card, "fair")
            f = card["fair"]
            pills = join(["""<span class="fair $(get(f, k, false) ? "yes" : "no")">$(uppercasefirst(k))</span>""" for k in ("findable", "accessible", "interoperable", "reusable")], " ")
            push!(rows, ("FAIR", pills * (haskey(f, "notes") ? " <span class=\"muted small\">$(esc(f["notes"]))</span>" : "")))
        end
        """<h2>Data card <span class="muted small">$(card_score(rec))/$(length(CARD_SECTIONS)) sections</span></h2>
$(kv(rows))"""
    end

    dists = join(["""<tr><td><a href="$(esc(d["url"]))">$(esc(get(d, "label", d["url"])))</a>$(badge(d["url"]))$(haskey(d, "notes") ? "<br><span class=\"muted small\">$(esc(d["notes"]))</span>" : "")</td>
<td>$(esc(d["role"]))</td><td>$(esc(vlabel(vocab, "hosts", d["host"])))</td><td>$(esc(join([vlabel(vocab, "formats", f) for f in get(d, "formats", [])], ", ")))</td>
<td>$(haskey(d, "size_bytes") ? bytes_str(d["size_bytes"]) * (haskey(d, "n_files") ? ", $(d["n_files"]) files" : "") : "")</td></tr>""" for d in rec["distributions"]], "\n")

    lic = rec["license"]
    lic_html = lic in ("unknown", "none-stated", "proprietary") ? esc(vlabel(vocab, "licenses", lic)) : """<a href="https://spdx.org/licenses/$(esc(lic)).html">$(esc(lic))</a>"""
    haskey(rec, "license_url") && (lic_html *= """ · <a href="$(esc(rec["license_url"]))">terms</a>""")
    haskey(rec, "license_notes") && (lic_html *= """<br><span class="muted small">$(esc(rec["license_notes"]))</span>""")
    er = get(rec, "energy_range", nothing)
    per = get(rec, "period", Dict())
    data = get(rec, "data", Dict()); model = get(rec, "model", Dict()); sw = get(rec, "software", Dict()); sv = get(rec, "service", Dict())
    yn(x) = x === nothing ? "" : x ? "yes" : "no"
    meta = kv([
        ("Creators", join(agent_html.(get(rec, "creators", [])), "; ")),
        ("Owner", haskey(rec, "owner") ? agent_html(rec["owner"]) : ""),
        ("Publisher", haskey(rec, "publisher") ? agent_html(rec["publisher"]) : ""),
        ("Maintainers", join(agent_html.(get(rec, "maintainers", [])), "; ")),
        ("Version", esc(get(rec, "version", ""))),
        ("Published", esc(get(rec, "date_published", ""))),
        ("Last updated", esc(get(rec, "date_updated", get(st, "upstream_updated", "")))),
        ("Licence", lic_html),
        ("Access", ACCESS_LABEL[rec["access"]]),
        ("Experiments", join([""" <a href="$(r)experiments/$(e)/">$(esc(exp_name(vocab, e)))</a>""" for e in get(rec, "experiments", [])], ", ")),
        ("Detectors", esc(join([det_name(vocab, d) for d in get(rec, "detectors", [])], ", "))),
        ("Collaborations", esc(join(get(rec, "collaborations", []), ", "))),
        ("Channels", esc(join([vlabel(vocab, "channels", c) for c in get(rec, "channels", [])], ", "))),
        ("Flavours", esc(join(get(rec, "flavors", []), ", "))),
        ("Detector technology", esc(join([vlabel(vocab, "detector_technologies", c) for c in get(rec, "detector_technologies", [])], ", "))),
        ("Energy range", er === nothing ? "" : "$(er["min"])–$(er["max"]) $(er["unit"])$(haskey(er, "quantity") ? " ($(esc(er["quantity"])))" : "")"),
        ("Data taking", isempty(per) ? "" : "$(get(per, "start", "?")) – $(get(per, "end", ""))"),
        ("Exposure", esc(get(rec, "exposure", ""))),
        ("Data levels", esc(join([vlabel(vocab, "data_levels", l) for l in get(data, "levels", [])], ", "))),
        ("Observables", esc(join(get(data, "observables", []), ", "))),
        ("Binning", esc(get(data, "binning", ""))),
        ("Events", haskey(data, "n_events") ? string(data["n_events"]) : ""),
        ("Covariance / systematics / MC", haskey(data, "has_covariance") || haskey(data, "has_systematics_model") || haskey(data, "has_mc") ?
            "$(yn(get(data, "has_covariance", nothing))) / $(yn(get(data, "has_systematics_model", nothing))) / $(yn(get(data, "has_mc", nothing)))" : ""),
        ("Usage code", haskey(data, "usage_code") ? """<a href="$(esc(data["usage_code"]))">$(esc(data["usage_code"]))</a>""" : ""),
        ("Result of", haskey(data, "result_of") ? doi_link(data["result_of"]) : ""),
        ("Quantities", esc(join(get(model, "quantities", []), ", "))),
        ("Targets", esc(join(get(model, "targets", []), ", "))),
        ("Validity", esc(get(model, "validity", ""))),
        ("Languages", esc(join(get(sw, "languages", []), ", "))),
        ("Purpose", esc(join([vlabel(vocab, "software_purposes", p) for p in get(sw, "purposes", [])], ", "))),
        ("Packages", esc(join(["$k: $v" for (k, v) in get(sw, "package_ids", Dict())], ", "))),
        ("Dependencies", esc(join(get(sw, "dependencies", []), ", "))),
        ("Development", esc(get(sw, "development_status", ""))),
        ("API", haskey(sv, "api") ? """<a href="$(esc(sv["api"]))">$(esc(sv["api"]))</a> ($(esc(get(sv, "api_kind", ""))))""" : ""),
    ])

    others = filter(x -> !(x[1] in ("uses", "used_by")), rels)
    relhtml = isempty(others) ? "" : "<h2>Related</h2><ul>" * join(["<li>$(esc(rel_label(rl))) $(target_html(t, byid; r))$(isempty(n) ? "" : " <span class=\"muted\">— $(esc(n))</span>")</li>" for (rl, t, n) in others]) * "</ul>"
    refs = get(rec, "references", [])
    refhtml = isempty(refs) ? "" : "<h2>Papers</h2><ul>" * join(map(refs) do x
        parts = filter(!isempty, [haskey(x, "citation") ? esc(x["citation"]) : "", haskey(x, "doi") ? doi_link(x["doi"]) : "",
                                  haskey(x, "arxiv") ? """<a href="https://arxiv.org/abs/$(esc(x["arxiv"]))">arXiv:$(esc(x["arxiv"]))</a>""" : "",
                                  haskey(x, "url") ? """<a href="$(esc(x["url"]))">link</a>""" : ""])
        "<li>$(join(parts, " · ")) <span class=\"muted small\">($(esc(get(x, "relation", "describes"))))</span></li>"
    end) * "</ul>"
    cite = get(rec, "cite_as", [])
    citehtml = isempty(cite) ? "" : "<h2>How to cite</h2><ul>" * join(["<li>$(startswith(c, "doi:") ? doi_link(c[5:end]) : esc(c))</li>" for c in cite]) * "</ul>"
    usedby = usage_html(rec, rels, byid; r)
    cur = rec["curation"]
    curhtml = """<h2>Curation</h2>""" * kv([
        ("Status", STATUS_LABEL[cur["status"]] * " <span class=\"muted small\">(candidate: harvested, not reviewed · curated: reviewed metadata · verified: resource downloaded and checked against its paper)</span>"),
        ("Added", esc(cur["added"]) * (haskey(cur, "added_by") ? " by $(esc(cur["added_by"]))" : "")),
        ("Last reviewed", esc(get(cur, "last_reviewed", ""))),
        ("Link check", isempty(st) ? "" : esc(get(st, "checked", ""))),
        ("Curator notes", join(["<div>• $(esc(n))</div>" for n in get(cur, "quality_notes", [])])),
    ]) * """<p class="small"><a href="$(SITE.repo)/edit/main/records/$(rec["type"])/$(id).yaml">Edit this record</a> ·
<a href="$(SITE.repo)/issues/new?title=$(HTTP_escape("Record $id: "))">Report a problem</a> · <a href="record.json">JSON</a></p>"""

    body = """
<nav class="crumbs"><a href="$(r)records/">Browse</a> / <span>$(esc(type_label(rec["type"])))</span></nav>
<header class="entry-head">
  <h1>$(esc(rec["title"]))</h1>
  <p class="summary">$(esc(rec["short"]))</p>
  <div class="tags">$tags</div>
  <div class="links">$buttons</div>
</header>
<div class="prose">$(md(rec["description"]))</div>
$cardhtml
<h2>Get it</h2>
<div class="table-scroll"><table class="files"><tr><th>Location</th><th>Role</th><th>Host</th><th>Formats</th><th>Size</th></tr>$dists</table></div>
<h2>Metadata</h2>
$meta
$usedby
$refhtml
$citehtml
$relhtml
$curhtml"""
    ld = """<script type="application/ld+json">$(replace(JSON.json(jsonld(rec, vocab)), "</" => "<\\/"))</script>\n"""
    page("$(rec["title"]) · $(SITE.name)", body; depth = 2, description = rec["short"], active = "records", head = ld)
end
HTTP_escape(s) = join([c in 'A':'Z' || c in 'a':'z' || c in '0':'9' || c in "-_.~" ? string(c) : join(["%" * uppercase(string(b, base = 16, pad = 2)) for b in codeunits(string(c))]) for c in s])

function experiments_page(records, vocab)
    n(e) = count(r -> e["id"] in get(r, "experiments", []), records)
    rows = join(["""<tr><td><a href="$(e["id"])/">$(esc(e["name"]))</a></td><td>$(esc(join([vlabel(vocab, "sources", s) for s in get(e, "sources", [])], ", ")))</td>
<td>$(esc(get(e, "site", "")))</td><td>$(get(e, "start", ""))–$(get(e, "end", ""))</td><td>$(n(e))</td></tr>"""
                 for e in sort(vocab["experiments"], by = e -> (-n(e), lowercase(e["name"])))], "\n")
    body = """<h1>Experiments</h1>
<p class="summary">The experiment registry used to tag records (<a href="$(SITE.repo)/blob/main/vocab/experiments.yaml">vocab/experiments.yaml</a>).</p>
<div class="table-scroll"><table class="files"><tr><th>Experiment</th><th>Sources</th><th>Site</th><th>Data taking</th><th>Records</th></tr>$rows</table></div>"""
    page("Experiments · $(SITE.name)", body; depth = 1, active = "experiments")
end

function experiment_page(e, records, vocab)
    rs = filter(r -> e["id"] in get(r, "experiments", []), records)
    link(id) = (i = findfirst(x -> x["id"] == id, vocab["experiments"]); """<a href="../$(id)/">$(esc(vocab["experiments"][i]["name"]))</a>""")
    info = kv([("Collaboration", esc(get(e, "collaboration", ""))), ("Also known as", esc(join(get(e, "aliases", []), ", "))),
               ("Sources", esc(join([vlabel(vocab, "sources", s) for s in get(e, "sources", [])], ", "))),
               ("Technology", esc(join([vlabel(vocab, "detector_technologies", s) for s in get(e, "technology", [])], ", "))),
               ("Site", esc(get(e, "site", ""))), ("Data taking", "$(get(e, "start", ""))–$(get(e, "end", ""))"),
               ("Website", haskey(e, "website") ? """<a href="$(esc(e["website"]))">$(esc(e["website"]))</a>""" : ""),
               ("Detectors", join(["$(esc(d["name"]))$(haskey(d, "description") ? " <span class=\"muted\">— $(esc(d["description"]))</span>" : "") ($(count(r -> d["id"] in get(r, "detectors", []), rs)) records)" for d in get(e, "detectors", [])], "<br>")),
               ("Predecessor", haskey(e, "predecessor") ? link(e["predecessor"]) : ""), ("Successor", haskey(e, "successor") ? link(e["successor"]) : "")])
    body = """<nav class="crumbs"><a href="../">Experiments</a> / <span>$(esc(e["name"]))</span></nav>
<h1>$(esc(e["name"]))</h1>$info
<h2>Resources</h2><div class="cards">$(isempty(rs) ? "<p class=\"muted\">No records yet. <a href=\"$(SITE.repo)/issues/new?title=Resource%20for%20$(HTTP_escape(e["name"]))\">Suggest one</a>.</p>" : join(record_card.(rs, Ref(vocab); r = "../../"), "\n"))</div>"""
    page("$(e["name"]) · $(SITE.name)", body; depth = 2, active = "experiments")
end

function about_page(vocab, schema)
    vt(name; desc = true) = "<div class=\"table-scroll\"><table class=\"files\"><tr><th>id</th><th>label</th>$(desc ? "<th>description</th>" : "")</tr>" *
        join(["<tr><td><code>$(esc(v["id"]))</code></td><td>$(esc(v["label"]))</td>$(desc ? "<td>$(esc(get(v, "description", "")))</td>" : "")</tr>" for v in vocab[name]]) * "</table></div>"
    fields = join(["<tr><td><code>$(esc(k))</code></td><td>$(k in schema["required"] ? "required" : "")</td><td>$(esc(get(v, "description", get(v, "x-maps-to", ""))))</td></tr>"
                   for (k, v) in sort(collect(schema["properties"]), by = first)])
    body = """<h1>Schema &amp; about</h1>
<div class="prose">
<p>The Newtrinos Index catalogues public neutrino resources: data releases, results, model inputs, software and services.
It is maintained by the <a href="https://newtrinos-org.github.io/">Newtrinos</a> team next to the
<a href="https://newtrinos-org.github.io/newtrinos-verifications/">verifications</a>, which reproduce published results
with many of the resources listed here.</p>
<h2>How records are described</h2>
<p>Each record is one YAML file validated against the <a href="../schema/record.schema.json">JSON Schema</a>
(version $(esc(schema["x-schema-version"]))). The descriptive fields follow DataCite, schema.org and CodeMeta, so records
export to those formats (each page embeds schema.org JSON-LD). Neutrino-specific fields (experiment, neutrino source,
channel, flavour, energy range, data level) use the controlled vocabularies below.</p>
<p>Curated records carry a <b>data card</b> modelled on the <a href="https://sites.research.google/datacardsplaybook/">Data Cards Playbook</a>,
<i>Datasheets for Datasets</i> and <i>Model Cards</i>, translated to neutrino physics: intended and out-of-scope use,
provenance, composition, systematics, validation, known limitations and maintenance, plus the
<a href="https://dphep.web.cern.ch/">DPHEP</a> preservation level and a FAIR self-assessment.</p>
<p><b>Curation status</b>: <i>candidate</i>, harvested automatically and not yet reviewed; <i>curated</i>, metadata reviewed by a
person; <i>verified</i>, the resource was downloaded and checked against its paper (usually through a Newtrinos verification entry).</p>
<h2>Fields</h2>
<div class="table-scroll"><table class="files"><tr><th>field</th><th></th><th>notes</th></tr>$fields</table></div>
<h2>Vocabularies</h2>
<h3>Record types</h3><ul>$(join(["<li><b>$(esc(l))</b> (<code>$t</code>): $(esc(d))</li>" for (t, l, d) in TYPE_INFO]))</ul>
<h3>Neutrino sources</h3>$(vt("sources"))
<h3>Data levels</h3>$(vt("data_levels"))
<h3>Topics</h3>$(vt("topics"; desc = false))
<h3>Interaction channels</h3>$(vt("channels"; desc = false))
<h3>Detector technologies</h3>$(vt("detector_technologies"; desc = false))
<h3>Software purposes</h3>$(vt("software_purposes"; desc = false))
<h3>Hosts</h3>$(vt("hosts"; desc = false))
<h3>Formats</h3>$(vt("formats"; desc = false))
<h3>Licences</h3>$(vt("licenses"))
<h2>Licence</h2>
<p>The catalogue metadata is released under <a href="https://creativecommons.org/publicdomain/zero/1.0/">CC0</a>, the code under MIT.
The catalogued resources keep their own licences; the index only links to them.</p>
</div>"""
    page("Schema & about · $(SITE.name)", body; depth = 1, active = "about")
end

function catalog_csv(records, vocab)
    cols = ["id", "type", "title", "doi", "url", "experiments", "detectors", "sources", "topics", "license", "access", "date_published", "version", "status"]
    q(s) = "\"" * replace(string(s), "\"" => "\"\"") * "\""
    rows = [join(q.([r["id"], r["type"], r["title"], get(r, "doi", ""), get(r, "url_landing", r["distributions"][1]["url"]),
                     join(get(r, "experiments", []), ";"), join(get(r, "detectors", []), ";"), join(get(r, "sources", []), ";"), join(get(r, "topics", []), ";"),
                     r["license"], r["access"], get(r, "date_published", ""), get(r, "version", ""), r["curation"]["status"]]), ",") for r in records]
    join(vcat(join(cols, ","), rows), "\n") * "\n"
end

# ------------------------------------------------------------------------------------------------
# build
# ------------------------------------------------------------------------------------------------
function build()
    vocab = load_vocab()
    records = sort([rec for (_, rec) in load_records(dirs = ["records"])], by = r -> lowercase(r["title"]))
    candidates = [rec for (_, rec) in load_records(dirs = ["candidates"])]
    byid = Dict(r["id"] => r for r in records)
    rels = all_relations(records)
    status = load_status()
    schema = JSON.parsefile(SCHEMA_JSON)
    # on NFS, rm can fail with ENOTEMPTY while .nfs* files are released: then overwrite in place
    try rm(OUT, recursive = true, force = true) catch e; @warn "could not clear $OUT, overwriting" e end
    mkpath(OUT)
    cp(joinpath(@__DIR__, "assets"), joinpath(OUT, "assets"); force = true)
    mkpath(joinpath(OUT, "schema")); cp(SCHEMA_JSON, joinpath(OUT, "schema", "record.schema.json"); force = true)
    write(joinpath(OUT, "index.html"), home_page(records, vocab))
    for (d, html) in (("records", records_page(records, vocab)), ("experiments", experiments_page(records, vocab)), ("about", about_page(vocab, schema)))
        mkpath(joinpath(OUT, d)); write(joinpath(OUT, d, "index.html"), html)
    end
    for rec in records
        dst = joinpath(OUT, "records", rec["id"]); mkpath(dst)
        write(joinpath(dst, "index.html"), record_page(rec, vocab, byid, rels[rec["id"]], status))
        write(joinpath(dst, "record.json"), sorted_json(rec) * "\n")
    end
    for e in vocab["experiments"]
        dst = joinpath(OUT, "experiments", e["id"]); mkpath(dst)
        write(joinpath(dst, "index.html"), experiment_page(e, records, vocab))
    end
    write(joinpath(OUT, "index.json"), JSON.json([index_record(r, vocab, rels[r["id"]]) for r in records]))
    write(joinpath(OUT, "catalog.jsonld"), sorted_json(Dict("@context" => "https://schema.org", "@type" => "DataCatalog",
        "name" => SITE.name, "description" => SITE.tagline, "url" => "https://newtrinos-org.github.io/newtrinos-index/",
        "license" => "https://creativecommons.org/publicdomain/zero/1.0/", "dataset" => [jsonld(r, vocab) for r in records])) * "\n")
    write(joinpath(OUT, "catalog.csv"), catalog_csv(records, vocab))
    write(joinpath(OUT, ".nojekyll"), "")
    println("built $(length(records)) records ($(length(candidates)) candidates not published) → $OUT")
end

build()
