# Export Files

PublicExport data provides item names, metadata, and lookups used across the CLI.

## Files and locations

- Runtime export files live under the per-user XDG cache. `apps/wfdaemon/priv/` contains bundled
  seed/fallback copies useful for source inspection.
- Files are downloaded via `wfcli update --exports` (or `--all`) and related flags.
- The file list is controlled by `?EXPORT_FILES` in `apps/wfdaemon/src/wfcli_worldstate.erl`.

Common files:
- `ExportUpgrades_en.json` (mods/arcanes)
- `ExportWeapons_en.json`
- `ExportWarframes_en.json`
- `ExportResources_en.json`
- `ExportRecipes_en.json`
- `ExportRelicArcane_en.json`
- `ExportKeys_en.json`
- `ExportGear_en.json`
- `ExportSortieRewards_en.json`
- `ExportCustoms_en.json`
- `ExportDrones_en.json`
- `ExportFlavour_en.json`
- `ExportFusionBundles_en.json`
- `ExportRegions_en.json`
- `ExportSentinels_en.json`
- `ExportManifest.json`

## How exports are used

- Item and mod resolution maps are owned by `wfcli_resolve_registry.erl`.
- Resolution scans `resolver_export_files/0`, not every downloaded file; large Codex files do not belong on this path.
- Catalog requests ask `wfcli_source_manager` to validate required managed exports. Missing or
  invalid managed files are fetched atomically before query execution. Explicit custom
  `--exports-dir` paths are never modified and fail with `source_unavailable`.
- Worldstate name resolution can still fall back to raw identifiers when optional resolver data
  is unavailable.
- Export-backed commands build entities via `wfcli_entity_exports.erl`, which produces `row_map`, `extra_fields`, `fields`, and `haystack` for search/rendering.

## Fast search tips

Use `rg` to quickly scan `priv/` for identifiers or paths:

```bash
rg -n "Calendar1999" apps/wfdaemon/priv
rg -n "\/Lotus\/StoreItems\/" apps/wfdaemon/priv
rg -n "some_id_or_uniqueName" apps/wfdaemon/priv
```

If you need to search a single export:

```bash
rg -n "some_id_or_uniqueName" apps/wfdaemon/priv/ExportUpgrades_en.json
```

Helper scripts:

```bash
scripts/priv_search.sh "Calendar1999"
scripts/export_keys.py ExportUpgrades_en.json uniqueName name locName
```

More utilities live in `docs/developer/tools.md`.

## CLI export queries

Exports are queried via top-level commands:

- `wfcli mods` filters ExportUpgrades by type/polarity/rarity and text (description + level stats); mod results include level-based effects when present, `--raw` includes raw identifiers.
- `wfcli items` searches item names across export files. Exact `--file`/`file=...` selections load that file even when it is outside the default item set.
- `wfcli codex` deduplicates official records from the separate Codex export set; see `knowledge.md`.
- Both commands support `--limit`/`--offset` for pagination and `--exports-dir` to override the cache location.

Expressions like `type:MELEE polarity:V toxin` are supported, along with explicit flags. `--format` is an alias for `--output-format`.
`wfcli mods` colorizes `<DT_*_COLOR>` tags using terminal ANSI colors; helpers live in `wfcli_tty.erl` for reuse in other commands.
Operators: `key=value` (exact), `key!=value`, `key~value` (contains), `key>=N`, `key<=N`, `key>N`, `key<N`.
Boolean expressions use uppercase `AND`, `OR`, `NOT`, and parentheses. Adjacent expressions imply AND.
`|` is reserved for alternatives inside one filter (e.g., `file=ExportWeapons_en.json|ExportResources_en.json`).
`--output-format json` emits machine-readable results (mods and items).

`wfcli_exports_cli` owns focused-command argv/help only. `wfcli_catalog_client` sends opaque
query tokens and typed flags to the daemon. Daemon-owned `wfcli_exports_query` compiles requests,
and `wfcli_exports_store` owns source preparation, catalog caching, and execution.
`wfcli_exports_format` and `wfcli_exports_presentation` own terminal output. Unified query uses
the same daemon service and formatters rather than invoking the focused CLI.
