# Contributing

- Suggest a resource or report an error: open an issue (the record pages link to a prefilled one).
- Add or fix a record: pull request with the YAML file; CI validates it against the schema and builds the site.
- Only link to resources; never commit the data itself.
- Licence: state what the owner states (`none-stated` if nothing); do not guess. Put doubts in `curation.quality_notes`.
- `verified` means you downloaded the resource and checked it against its paper; say how in `card.validation`.

## Record ids

Lower-case slugs, `<experiment or owner>-<what>[-<year or version>]`, e.g. `daya-bay-full-data-release`,
`super-k-atm-2023-data-release`, `nufit-6`, `honda-atmospheric-flux-tables`. One record per release or product (not per
file or per HEPData table); group related releases with a `collection` record and `is_part_of` relations.

## Data extracted by Newtrinos

Tables that the Newtrinos developers digitised or vector-extracted from paper figures are catalogued too (they are
often the only machine-readable form): `owner: Newtrinos-org`, `data.levels` includes `digitized`, a distribution
pointing at the files in Newtrinos.jl, and `relations: [{rel: derived_from, target: "doi:<paper>"}]`.
