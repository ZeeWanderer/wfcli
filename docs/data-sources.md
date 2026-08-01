# Data Sources and Updates

## Sources

| Data | Source | Managed by |
| --- | --- | --- |
| Missions, cycles, alerts, fissures, and other live state | Official Warframe worldstate | Worldstate cache and watch service |
| Mods, items, recipes, names, and Codex records | Official PublicExport files | Managed export catalog |
| Enemies, drops, relic rewards, components, and image identities | WFCD `warframe-items` | Managed WFCD catalog |
| Star Chart mastery values | `warframe-public-export-plus` regions | Managed mastery catalog |
| Public listings and top orders | Warframe Market | Market cache and request queue |
| Inventory, mastery, and local game state | `wfcompanion` observation | Owner-only player store |

Parsers attach typed fields and resolved names without replacing source records. Unified queries
can use normalized fields or `data.<path>` values; see [Query language and watches](query.md).

## Manual Updates

```bash
wfcli update
wfcli update --default
wfcli update --all
```

No flags and `--default` refresh Sol nodes, languages, PublicExport files, WFCD data, and Star
Chart mastery values. `--all` selects every managed source.

Targeted metadata options:

- `--nodes`, `--languages`, `--manifest`, `--exports`
- `--recipes`, `--upgrades`, `--weapons`, `--warframes`, `--resources`
- `--wfcd`

Live-cache options are `--worldstate` and `--trader`. Run `wfcli update --help` for path
overrides and the complete option list.

## Automatic Refresh

`wfdaemon` checks managed metadata hourly and refreshes sources older than 24 hours. Missing or
invalid managed files are fetched when first needed. Refreshes share a serialized source queue and
publish completed files by atomic rename, so active readers retain a complete old version until a
new version is ready.

Worldstate, Market manifests and quotes, relic tables, and image assets use request-specific cache
policies. Failed refreshes retain the last valid cached value where available.

Explicit `--knowledge-dir` and `--exports-dir` paths are caller-owned: the daemon validates them but
does not modify them.

## Storage

Run `wfcli paths` to inspect config, cache, state, and runtime directories. Defaults follow XDG
variables and normally resolve beneath:

```text
~/.config/wfcli
~/.cache/wfcli
~/.local/state/wfcli
$XDG_RUNTIME_DIR/wfcli
```

Managed WFCD files record source URL, fetch time, and content SHA-256. Downloaded assets are
content-addressed so identical images share one cached object.
