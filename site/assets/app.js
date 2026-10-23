// Newtrinos Index: faceted browsing of records (from index.json).
(function () {
  const holder = document.querySelector("[data-root]") || document.body;
  const root = holder.dataset.root || "./";
  const list = document.getElementById("list");
  const facetsEl = document.getElementById("facets");
  if (!list || !facetsEl) return;

  const kind = (document.querySelector(".browse") || {}).dataset?.kind || "";
  const SOFTWARE_FACETS = [
    { key: "purpose", label: "Purpose", get: (e) => e.purposes || [] },
    { key: "language", label: "Language", get: (e) => e.languages || [] },
    { key: "source", label: "Neutrino source", get: (e) => e.sources },
    { key: "topic", label: "Topic", get: (e) => e.topics },
    { key: "experiment", label: "Experiment", get: (e) => e.experiments },
    { key: "devstatus", label: "Development", get: (e) => (e.devstatus ? [e.devstatus] : []) },
    { key: "license", label: "Licence", get: (e) => [e.license] },
    { key: "newtrinos", label: "Newtrinos", get: (e) => (e.newtrinos ? [e.newtrinos] : []) },
  ];
  const FACETS = kind === "software" ? SOFTWARE_FACETS : [
    { key: "type", label: "Kind", get: (e) => [e.type_label] },
    { key: "source", label: "Neutrino source", get: (e) => e.sources },
    { key: "experiment", label: "Experiment", get: (e) => e.experiments },
    { key: "detector", label: "Detector", get: (e) => e.detectors || [] },
    { key: "topic", label: "Topic", get: (e) => e.topics },
    { key: "level", label: "Data level", get: (e) => e.levels },
    { key: "access", label: "Access", get: (e) => [e.access] },
    { key: "license", label: "Licence", get: (e) => [e.license] },
    { key: "status", label: "Curation", get: (e) => [e.status] },
    { key: "newtrinos", label: "Newtrinos", get: (e) => (e.newtrinos ? [e.newtrinos] : []) },
  ];
  const STATUS = { candidate: "Candidate", curated: "Curated", verified: "Verified" };
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

  const params = new URLSearchParams(location.search);
  const state = {};
  FACETS.forEach((f) => (state[f.key] = new Set(params.getAll(f.key))));
  const search = document.getElementById("search");
  const sort = document.getElementById("sort");
  search.value = params.get("q") || "";
  sort.value = params.get("sort") || "title";
  let records = [];

  function matches(e, skip) {
    for (const f of FACETS) {
      if (f.key === skip || state[f.key].size === 0) continue;
      if (!f.get(e).some((v) => state[f.key].has(v))) return false;
    }
    const words = search.value.trim().toLowerCase().split(/\s+/).filter(Boolean);
    const hay = [e.title, e.short, e.doi, e.id, e.keywords, e.experiments.join(" "), (e.detectors || []).join(" "), e.sources.join(" "), e.topics.join(" ")].join(" ").toLowerCase();
    return words.every((w) => hay.includes(w));
  }

  function card(e) {
    const tags = `<span class="tag cat">${esc(e.type_label)}</span> ` + e.experiments.concat(e.detectors || []).map((x) => `<span class="tag exp">${esc(x)}</span>`).join(" ") +
      " " + e.sources.filter((s) => s !== "Not source-specific").map((x) => `<span class="tag">${esc(x)}</span>`).join(" ") +
      ` <span class="tag status-${e.status}">${esc(STATUS[e.status] || e.status)}</span>`;
    return `<article class="card">
      <a class="card-link" href="${root}records/${esc(e.id)}/"><h3>${esc(e.title)}</h3><p class="muted">${esc(e.short)}</p></a>
      <div class="tags">${tags}</div>
      <div class="meta muted">${e.year ? esc(e.year) + " · " : ""}${esc(e.license)} · ${esc(e.access)}${e.card ? ` · data card ${e.card}/11` : ""}${e.users ? ` · used by ${e.users}` : ""}</div>
    </article>`;
  }

  function renderFacets() {
    facetsEl.innerHTML = FACETS.map((f) => {
      const counts = {};
      records.filter((e) => matches(e, f.key)).forEach((e) => f.get(e).forEach((v) => (counts[v] = (counts[v] || 0) + 1)));
      const values = [...new Set(records.flatMap(f.get))].sort((a, b) => (counts[b] || 0) - (counts[a] || 0) || a.localeCompare(b));
      if (!values.length) return "";
      const items = values.map((v) => `<label><span><input type="checkbox" data-facet="${f.key}" value="${esc(v)}" ${state[f.key].has(v) ? "checked" : ""}>${esc(f.key === "status" ? STATUS[v] || v : v)}</span><span class="n">${counts[v] || 0}</span></label>`).join("");
      return `<div class="facet"><h4>${f.label}</h4>${items}</div>`;
    }).join("") + `<a href="#" class="clear" id="clear">Clear all</a>`;
    facetsEl.querySelectorAll("input").forEach((i) => i.addEventListener("change", () => {
      i.checked ? state[i.dataset.facet].add(i.value) : state[i.dataset.facet].delete(i.value);
      update();
    }));
    document.getElementById("clear").addEventListener("click", (ev) => {
      ev.preventDefault();
      FACETS.forEach((f) => state[f.key].clear());
      search.value = "";
      update();
    });
  }

  function update() {
    const shown = records.filter((e) => matches(e));
    shown.sort({
      title: (a, b) => a.title.localeCompare(b.title),
      added: (a, b) => b.added.localeCompare(a.added),
      newest: (a, b) => (b.year || "").localeCompare(a.year || ""),
      card: (a, b) => b.card - a.card || a.title.localeCompare(b.title),
      updated: (a, b) => (b.updated || "").localeCompare(a.updated || ""),
      users: (a, b) => b.users - a.users || a.title.localeCompare(b.title),
    }[sort.value]);
    list.innerHTML = shown.map(card).join("") || `<p class="muted">No records match.</p>`;
    document.getElementById("count").textContent = `${shown.length} / ${records.length} records`;
    const p = new URLSearchParams();
    FACETS.forEach((f) => state[f.key].forEach((v) => p.append(f.key, v)));
    if (search.value) p.set("q", search.value);
    if (sort.value !== "title") p.set("sort", sort.value);
    try { history.replaceState(null, "", p.toString() ? `?${p}` : location.pathname); } catch (e) { /* sandboxed preview */ }
    renderFacets();
  }

  search.addEventListener("input", update);
  sort.addEventListener("change", update);
  fetch(`${root}index.json`).then((r) => r.json()).then((d) => { records = kind ? d.filter((e) => e.type === kind) : d; update(); })
    .catch(() => { facetsEl.innerHTML = `<p class="muted">Filters unavailable (index.json could not be loaded).</p>`; });
})();
