# Static Knowledge Catalogs

Static knowledge is split by provenance. Do not silently merge community data into official
records.

## Official Codex

`wfcli codex` builds entities from the PublicExport files listed by
`wfcli_worldstate:codex_export_files/0`. `wfcli update --exports` and the default managed update
path fetch them. Records with `excludeFromCodex=true` are hidden unless the caller passes
`--include-excluded`.
The reported version is a SHA-256 of the normalized, deduplicated official catalog.

PublicExport file selection has three deliberate scopes:

- `export_files/0`: every official file wfcli downloads.
- `resolver_export_files/0`: the smaller set scanned for identifier resolution.
- `codex_export_files/0`: files that contribute user-searchable static knowledge.

Keep these scopes separate. Adding large lore/region files to identifier resolution increases
startup and reindex cost without improving most worldstate output.

## WFCD Data

`wfcli enemies` and `wfcli drops` use WFCD `warframe-items` `Enemy.json`. It combines official
exports with community drop data and wiki-derived enrichment. Default updates and unified queries
include it. Explicit `enemies`, `drops`, or matching unified queries prepare a missing or invalid
managed copy on demand. `wfcli update --wfcd` requests an immediate refresh.

The ignored research clone used to establish the contract was `WFCD/warframe-items` commit
`f2150533934a067d493caef38c733a01d4935e28`. Re-audit the upstream build inputs before expanding
the local schema; fields may have mixed provenance.

WFCD includes internal base/leader variants that can render identically. Loaders collapse only
display-identical normalized enemies and drop rows; materially different stats, descriptions,
resistances, or drop tables remain separate.

## Daemon Ownership

`wfcli_exports_store` owns one serialized query queue for all static catalogs. It caches fully
built entities by source file signature, not only decoded JSON. `wfcli_knowledge_cli` parses
focused-command argv, then `wfcli_catalog_client` sends opaque query tokens and typed flags.
Daemon-owned `wfcli_knowledge_query` compiles and executes requests.
`wfcli_knowledge_format` and `wfcli_knowledge_presentation` render data-only replies. Unified
query calls the same daemon service and formatter. Pure loaders/builders remain directly
testable, but only daemon services call them in production.

`wfcli_source_manager` checks managed nodes, languages, PublicExport files, and the WFCD wrapper
periodically. Stale refresh jobs share its serialized queue with explicit updates. Metadata files
are atomically replaced; catalog signatures cause later requests to rebuild cached entities.

Knowledge commands compile through `wfcli_query_parse` and execute through
`wfcli_entity_query`. CLI modules must not implement a second filter/sort engine or call each
other to reuse catalog behavior.
