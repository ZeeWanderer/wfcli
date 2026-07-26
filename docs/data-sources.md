# Data Sources and Updates

`wfcli update` refreshes data used to resolve names and search catalogs.

## Normal Updates

```bash
wfcli update
wfcli update --default
wfcli update --all
```

No flags and `--default` refresh the official default metadata. `--all` also refreshes
optional WFCD enemy and drop data.

Targeted updates:

- `--nodes`: Sol node names.
- `--languages`: translated worldstate strings.
- `--manifest`: official PublicExport manifest.
- `--exports`: all PublicExport metadata files.
- `--recipes`, `--upgrades`, `--weapons`, `--warframes`, `--resources`: selected exports.
- `--wfcd`: optional versioned WFCD enemy and drop catalog.
- `--worldstate`: live worldstate cache.
- `--trader`: trader inventory cache.

## Storage

Worldstate, trader, Sol node, language, manifest, PublicExport, managed WFCD, player, and market caches live
under `$XDG_CACHE_HOME/wfcli`, or `~/.cache/wfcli` when `XDG_CACHE_HOME` is unset.
`--cache FILE` overrides the worldstate path. Files under `apps/wfdaemon/priv/` are bundled
seeds/read-only fallbacks, not runtime update targets. Item names are resolved from official
hashed PublicExport manifests.
`--raw` bypasses name translation and keeps raw identifiers and UTC timestamps.

`market.term` stores Warframe Market item metadata and successful top-order quotes. Market
requests identify wfcli, use PC/cross-play/English context, share one three-request-per-second
daemon limiter, and fall back to stale cached quotes when refresh fails.

WFCD data is external and optional. Default updates deliberately omit it. An explicit
`enemies`, `drops`, or matching unified query fetches the managed WFCD copy when it is
missing or invalid. Use `--wfcd` or `--all` only to refresh it proactively. Custom
`--knowledge-dir` and `--exports-dir` paths are strict: missing files are reported and
never populated automatically.

Use `wfcli update --help` for every granular source and cache override.
