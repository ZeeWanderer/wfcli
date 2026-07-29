# Command-Line Client

`wfcli` is the terminal and stdio MCP interface to `wfdaemon`. It parses
arguments and formats daemon replies; network access, persistence, queries, and
planning stay in the daemon.

## Help

These forms are equivalent and contextual:

```bash
wfcli help daemon autostart
wfcli daemon autostart help
wfcli daemon autostart --help
wfcli daemon autostart -h
```

Use `wfcli help commands` for the command list. Focused data commands provide
common views; `query`, `forma-plan`, daemon control, and companion diagnostics
have linked guides below.

Commands narrow an operation. Options modify an operation and may be composed.
Where both forms improve shell use, the CLI accepts both:

```bash
wfcli baro inventory
wfcli baro --inventory
wfcli archimedea deep
wfcli archimedea --deep
```

## Bash Completion

Install completion in `~/.bashrc`:

```bash
wfcli completion install
wfcli completion status
wfcli completion uninstall
```

Use `--file PATH` with these commands for another Bash startup file. For the
current shell only:

```bash
source <(wfcli completion bash)
```

The generated function completes from in-memory command data and registers both
`wfcli` and `wfclid`.

## Per-User Paths

```bash
wfcli paths
wfcli paths wfdaemon
wfcli daemon paths
wfcli companion paths
wfdaemon paths
wfcompanion paths
```

The report lists each application's XDG directories without creating them. An
exact directory symlink is shown as `PATH -> TARGET`.

## Guides

- [Query language and watches](query.md)
- [Data sources and updates](data-sources.md)
- [Daemon lifecycle](daemon.md)
- [Linux/Proton companion](companion.md)
- [Forma planning](forma-plan.md)
- [MCP server](mcp.md)
