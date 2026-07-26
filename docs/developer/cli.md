# CLI Architecture

## Dispatch

- `wfcli_cli.erl` routes `wfcli <command>` to module handlers.
- Worldstate commands (alerts, fissures, etc) are top-level. `wfcli_worldstate_cli.erl`
  handles arguments and one-shot requests, `wfcli_worldstate_watch_cli.erl` owns daemon
  subscriptions, and `wfcli_worldstate_output.erl` owns terminal rendering.
- Export commands (mods, items) are top-level; `wfcli_exports_cli.erl` handles argv and help.
- Knowledge commands (Codex, enemies, drops) are top-level; `wfcli_knowledge_cli.erl` handles argv and help.
- Unified search is handled by `wfcli_query_cli.erl`.
- Updates are centralized in `wfcli_update_cli.erl`.
- Shared help text snippets live in `wfcli_help_text.erl`.

## Parsing

- `parse_args/2` accumulates a map of options and validates combinations.
- Put command-specific detail in subcommand help rather than expanding top-level help.
- Use layered help: summaries at top level, command/topic-specific detail in `help <topic>` or `<command> --help`.
- Use `--no-suggest-prompt` to disable interactive correction prompts for mistyped commands/flags.
- Watch specs use `watch_type_filter/1`; update both parse and watch paths for new commands.
- Inventory mode (`--inventory`) is only valid for baro/prime-vault.
- Calendar supports `--day N` and validates it against the calendar subcommand.
- Query sorting is expressed in the query language (`sort=field`, `sort=-field`) and applied after filtering.
- Unified-query dataset selection is also query semantics:
  `dataset=default|worldstate|mods|items|codex|enemies|drops|player|market|all`. Keep it opaque in the CLI;
  the daemon extracts it before dataset dispatch.
- Focused CLI modules convert explicit flags into request maps but preserve query tokens as text.
  Daemon query services parse and compile both focused and unified requests.
- CLI modules must not call another CLI module or reconstruct argv to reuse behavior. Focused and
  unified commands submit through `wfcli_catalog_client`.
  Do not add command-local matching, numeric comparison, boolean, sorting, or paging logic.
- `sort=` and `dataset=` are controls, not match predicates. They are valid only as positive
  top-level AND clauses, never inside OR or NOT.

## Output

- Default output is table format; `--output-format block` uses block rows.
- `--format` is an alias for `--output-format`.
- Export and knowledge commands also accept `--output-format json` for machine-readable output.
- Any command that accepts `--output-format` should also accept `--format` as an alias.
- Prefer shared helpers in `wfcli_tty.erl` for terminal width, ANSI-aware column sizing, and `DT_*_COLOR` tag colorization so output stays consistent across commands.
- Use `wfcli_table:render_lines/3` for table rendering, wrapping, and inline diff coloring.
- Provide column specs (roles/optional) to `wfcli_table`; avoid per-command width/priority tuning.
- Table output may add a small set of adaptive columns based on sparse `extra_fields` in entries.
- Block output uses CLI-owned `wfcli_*_presentation` specs, then appends remaining `row_map` keys
  and `extra_fields`.
- Export-backed commands build entries via `wfcli_entity_exports.erl` to keep rendering/search consistent with worldstate.
- Use `wfcli_text:to_list/1` for shared string coercion instead of re-implementing helpers in each module.
- Use `wfcli_text:join_list/2` and `wfcli_text:join_parts/2` when formatting lists/parts across modules.
- Use `wfcli_data_extract` for dot-path extraction across data sources.
- All queryable entities use daemon-owned `wfcli_query_parse` plus `wfcli_entity_query`; add
  syntax/evaluator behavior there and field metadata in the owning `wfcli_entity_*` module.
- Catalog terminal output belongs to `wfcli_exports_format` and `wfcli_knowledge_format`, shared by
  focused and unified commands.
- Table columns and labels are stable contracts in `wfcore` schema modules. Terminal block
  ordering belongs in CLI presentation modules.
- `print_entries/4` and `table_row_map/2` keep output consistent.
- Any command or subcommand that resolves translated names by default must accept `--raw` to keep identifiers/UTC timestamps.

## Adding a command (worldstate-backed)

1) Add `parse_args` clause to set `type_filter` or `command_defaults/1`.
2) Add `watch_type_filter` entry if relevant.
3) Add columns in `wfcli_worldstate_schema` and block fields in
   `wfcli_worldstate_presentation` when needed.
4) If it resolves translated names, wire `--raw` to bypass translations and document it.
5) Update the README command map or linked user guide, plus `docs/developer/*` as needed.
