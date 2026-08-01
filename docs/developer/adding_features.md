# Adding Features

Use this checklist after choosing the owning application in [`structure.md`](structure.md).

## Worldstate-derived features

- Use daemon-owned `wfcli_resolve:resolve/3` for name resolution and translation (keys like
  `item`, `node`, `faction`, `missiontype`, `modifier`, `season`, `dt`, `any`).
- Use `wfcli_worldstate_projector` for semantic display values such as expiry windows.
- Use the existing index pattern:
  - Build entries in `wfcli_worldstate:index_raw/2`.
  - Use `wfcli_entity_worldstate:build/5` for sparse optional fields.
  - Add query fields/default sorts in daemon entity metadata.
  - Add shared table columns in `wfcli_worldstate_schema`.
  - Add terminal block order in `wfcli_worldstate_presentation`.

## CLI features

- Keep parsing centralized in `wfcli_worldstate_cli.erl`.
- Use subcommands for scope and options for composable behavior.
- If help is getting long, add subcommand help.
- Reuse shared help text helpers in `wfcli_help_text.erl` where possible.
- Update command registries, `known_args/0`, contextual help, and completion tests.

## New data sources

- Favor `languages.json` for display strings when the key exists.
- Export data is loaded from the managed XDG cache with `apps/wfdaemon/priv` as bundled fallback.
- Add managed exports to `?EXPORT_FILES` in
  `apps/wfdaemon/src/catalog/wfcli_metadata_update.erl` and place them in only the resolver or
  Codex scope that needs them.
- For exports-backed commands, build entries via `wfcli_entity_exports.erl` so table rendering/search stays consistent.
- Add managed-source requirements in `wfcli_source_manager`; never write into explicit custom
  source directories.

## Tests

- Add focused EUnit or Common Test coverage under the owning application's test directory.
- Update `apps/wfcli/test/fixtures/worldstate_sample.json` only when the feature needs source data
  absent from the fixture.
