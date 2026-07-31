# Data Sources and Updates

`wfcli update` refreshes managed metadata used for name resolution and catalog
queries.

## Updates

```bash
wfcli update
wfcli update --default
wfcli update --all
```

No flags and `--default` refresh the standard managed set: Sol nodes,
languages, PublicExport files, and WFCD enemy/drop data. `--all` selects every
managed source.

Targeted options:

- `--nodes`, `--languages`, `--manifest`, `--exports`
- `--recipes`, `--upgrades`, `--weapons`, `--warframes`, `--resources`
- `--wfcd`
- `--worldstate`, `--trader`

Run `wfcli update --help` for cache-path options and the complete list.

## Automatic Refresh

While running, `wfdaemon` checks managed metadata hourly and refreshes sources
older than 24 hours. Refreshes use the source manager's serialized queue.
Completed files are published by atomic rename. In-flight requests keep their
loaded data; later loads observe complete replacement files.

Missing or invalid managed catalog files are also fetched on demand. Explicit
`--knowledge-dir` and `--exports-dir` paths are strict: the daemon reports bad
files and never writes into those directories.

Warframe Market manifests, relic tables, quotes, and image assets have separate
stale-on-use policies because they are request-driven.

## Storage

Managed data lives under the directories reported by:

```bash
wfcli paths
```

Defaults follow XDG variables, normally `~/.cache/wfcli`,
`~/.local/state/wfcli`, `~/.config/wfcli`, and
`$XDG_RUNTIME_DIR/wfcli`. `--raw` bypasses name translation and keeps source
identifiers and UTC timestamps.

WFCD data is external community data. The managed wrapper records source URL,
fetch time, and content SHA-256. Custom source paths remain caller-owned.

`WFCDItems.json` is a compact managed projection of WFCD `All.json`. Inventory and Mastery views
use it for names, components, mastery metadata, relic drops, and image identities. It follows the
same periodic refresh policy as other managed WFCD data.
