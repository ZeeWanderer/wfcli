# Adding Features

This is a checklist to avoid reinventing existing helpers.

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
- Prefer new flags over ad hoc parsing.
- If help is getting long, add subcommand help.
- Reuse shared help text helpers in `wfcli_help_text.erl` where possible.

## New data sources

- Favor `languages.json` for display strings when the key exists.
- Export data is loaded from the managed XDG cache with `apps/wfdaemon/priv` as bundled fallback.
- Add new exports to the `?EXPORT_FILES` list in `wfcli_worldstate.erl` if needed.
- For exports-backed commands, build entries via `wfcli_entity_exports.erl` so table rendering/search stays consistent.
- Add managed-source requirements in `wfcli_source_manager`; never write into explicit custom
  source directories.

## Tests

- Add tests in `apps/wfcli/test/wfcli_worldstate_SUITE.erl`.
- Update `apps/wfcli/test/fixtures/worldstate_sample.json` when you need new fixture data.
