# Shared Utilities

`wfcore` is a process-free OTP library. It exists because every BEAM module must have one
application owner; compiling the same source into both executable applications creates module
clashes in xref and ambiguous debugger paths.

- `wfcli_protocol`: protocol version, request ownership, and dataset contracts.
- `wfcli_build`: staged artifact flavor, install root, and update paths.
- `wfcli_paths`: XDG cache, state, config, and runtime paths.
- `wfcli_*_schema`: column contracts used by daemon sorting and CLI tables.
- `wfcli_text`, `wfcli_time`, `wfcli_polarity`: deterministic value helpers.
- `wfcli_data_extract`, `wfcli_worldstate_diff`: data-only extraction and diff values.

Do not add fetching, persistence, processes, CLI parsing, or rendering to `wfcore`. Two callers
inside one application do not justify moving code here; a stable contract needed by both
applications does.

CLI-only examples: `wfcli_tty`, `wfcli_table`, `wfcli_cli_args`.

Daemon-only examples: `wfcli_data_cache`, `wfcli_query_parse`, `wfcli_entity_*`.

Exported inter-module functions require `-spec` and terse `-doc` text where purpose or ownership is
not obvious. Shared behavior changes require focused EUnit or Common Test coverage.
