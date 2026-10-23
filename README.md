# Newtrinos Index

A curated, machine-readable catalogue of public neutrino resources: data releases, results (likelihoods, Δχ² maps,
global-fit tables), model inputs (fluxes, cross sections, solar and Earth models), software and services.

Site: https://newtrinos-org.github.io/newtrinos-index/ · part of [Newtrinos](https://newtrinos-org.github.io/), next to
the [verifications](https://newtrinos-org.github.io/newtrinos-verifications/).

## Layout

| Path | Content |
|---|---|
| `records/<type>/<id>.yaml` | one file per resource (`type`: dataset, result, model, software, service, collection) |
| `candidates/<type>/<id>.yaml` | harvested or scaffolded records awaiting review (not published) |
| `vocab/*.yaml` | controlled vocabularies and the experiment registry |
| `schema/record.schema.yaml` | schema source; `record.schema.json` is generated from it and `vocab/` |
| `tools/` | `validate.jl`, `gen_schema.jl`, `new_record.jl` (scaffold from a DOI or GitHub URL) |
| `site/` | static-site generator (`build.jl`) and assets |
| `test/` | validator tests (`good/` must pass, `bad/` must fail) |

## What a record contains

Descriptive metadata aligned with DataCite / schema.org / CodeMeta: identifiers (DOI, arXiv, INSPIRE, Zenodo,
SWHID), creators, owner, publisher, maintainers, version history, dates, SPDX licence, access level, and
**distributions**, i.e. every place to get the resource (primary, mirrors, archive copies) with host, formats and size.
Then the neutrino classification: experiments, sources, topics, channels, flavours, detector technology, energy range,
data-taking period, exposure. There are type-specific blocks (`data`, `model`, `software`, `service`), links to Newtrinos
modules and verification entries, and curation metadata.

Curated records carry a **data card** (`card:`) following the
[Data Cards Playbook](https://sites.research.google/datacardsplaybook/), Datasheets for Datasets and Model Cards:
intended and out-of-scope use, provenance, composition, systematics, validation, known limitations, maintenance,
plus the DPHEP preservation level and a FAIR self-assessment. `verified` records must have one.

## Adding a record

```sh
julia --project -e 'using Pkg; Pkg.instantiate()'                 # once
julia --project tools/new_record.jl 10.5281/zenodo.17587229 --write  # scaffold into candidates/
# edit: classification, card, ids; move to records/<type>/ and set curation.status: curated
julia --project tools/validate.jl
julia --project site/build.jl && python3 -m http.server -d public  # preview
```

When you add an entry to `vocab/`, regenerate the schema with `julia --project tools/gen_schema.jl`.
Relations are stated on one side only (e.g. `uses`); the site shows the inverse (`used by`).

## Licences

Catalogue metadata (records, vocabularies): [CC0 1.0](LICENSE-CC0-1.0.txt). Code: [MIT](LICENSE).
The catalogued resources keep their own licences.
