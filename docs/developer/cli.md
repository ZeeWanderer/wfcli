# CLI Architecture

## Commands

`wfcli_cli` assembles the command tree and owns top-level grouping. Each command module declares
its OTP `argparse` specification beside its handler: arguments, types, defaults, subcommands,
summary and optional notes. Handlers receive parsed maps, not argv.
Enum types supply completion values; use argument `completion` hints for open-ended values.

- `wfcli_cli_args` supplies shared argument definitions and contextual help adaptation.
- `wfcli_catalog_cli` handles focused export and knowledge queries.
- `wfcli_query_cli` handles unified queries and the player view.
- `wfcli_worldstate_cli` handles one-shot requests and watch-spec syntax;
  `wfcli_worldstate_watch_cli` owns subscription lifetime.
- `wfcli_update_cli` is the update entry point.

Add a subcommand when it narrows an operation; use options for composable modifiers.
Define each argument once. Do not add separate option registries, hand-written argv parsers or
copied help tables. Generated help and Bash completion consume the same tree.
Keep domain validation, such as mutually exclusive scopes, in the owning handler.

The query DSL reaches the daemon uncompiled. Focused flags become typed filters; free query text
stays opaque. Preserve literal tails after `--`. Reuse behavior through typed functions or shared
clients, never by rebuilding argv and invoking another parser. Matching, sorting, pagination and
`dataset=` interpretation belong to daemon query services.

## Help And Completion

`help COMMAND`, `COMMAND help`, `COMMAND --help` and `COMMAND -h` resolve the same scope.
Values named `help` remain values. Typo correction requires terminal stdin and stdout and respects
`--no-suggest-prompt`.

`wfcli_completion` generates static Bash maps and a builtin-only completion function. Builds stage
them under `share/bash-completion/completions` for lazy loading. Keep Bash 5.3 `compgen -V`:
neither shell initialization nor completion may start an Erlang VM. Tests execute the generated
script with external commands unavailable.

## Output

Usage errors use stderr and exit 2; failed operations exit 1. Help and successful data use stdout.
Batch commands retain successful results while returning failure if any job fails.

Use `wfcli_table` and `wfcli_tty` for terminal layout. Shared schema modules define columns;
CLI presentation modules define block ordering. Focused and unified queries share
`wfcli_exports_format` and `wfcli_knowledge_format`.

Catalog JSON uses explicit field types in `wfcli_catalog_json`. Never infer strings from integer
arrays or empty lists. Preserve nested source JSON types. Use `wfcli_data_extract` for dot paths
and `wfcli_text` for shared string conversion.

## Verification

Test specifications and handlers, then actual child-process stdout, stderr, exit codes, literal
arguments and partial failures. Keep help/completion coverage tree-driven so new commands join
the same checks. Architecture boundaries and interface versioning are in
[daemon.md](daemon.md); feature wiring is in [adding_features.md](adding_features.md).
