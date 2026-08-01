# Command-Line Client

`wfcli` parses commands, submits typed requests to `wfdaemon`, and formats replies. Fetching,
persistence, query execution, and planning remain daemon-owned.

## Commands

Focused commands provide common Warframe views without query syntax:

```bash
wfcli fissures
wfcli alerts --watch
wfcli sorties
wfcli baro inventory
wfcli teshin
wfcli archimedea
```

Catalog and account commands search one domain with domain-specific output:

```bash
wfcli mods toxin
wfcli items braton
wfcli codex 'critical chance'
wfcli enemies corrupted
wfcli drops serration
wfcli market 'saryn prime set'
wfcli player
```

Advanced operations have dedicated guides:

- [`query` and `watch`](query.md): cross-dataset expressions and subscriptions
- [`forma-plan` and `visualize`](forma-plan.md): polarity planning
- [`daemon`](daemon.md): service lifecycle and updates
- [`companion`](companion.md): game observer and overlay control
- [`mcp`](mcp.md): structured stdio integration

Run `wfcli help commands` for every focused worldstate command.

## Help

Help is contextual; these forms are equivalent:

```bash
wfcli help daemon autostart
wfcli daemon autostart help
wfcli daemon autostart --help
wfcli daemon autostart -h
```

Commands narrow an operation. Options modify it. Where both forms improve shell use, both are
accepted:

```bash
wfcli baro inventory
wfcli baro --inventory
wfcli archimedea deep
wfcli archimedea --deep
```

## Bash Completion

Install generated completion in `~/.bashrc`:

```bash
wfcli completion install
wfcli completion status
wfcli completion uninstall
```

Use `--file PATH` for another Bash startup file. For one shell:

```bash
source <(wfcli completion bash)
```

Completion data is embedded in the generated shell function, so Tab completion does not start an
Erlang VM.

## Application Paths

```bash
wfcli paths
wfcli paths wfdaemon
wfcli companion paths
```

The report lists each application's XDG directories without creating them. Directory symlinks are
shown as `PATH -> TARGET`.

## Fissure Notifications

```bash
wfcli notifications status
wfcli notifications off
wfcli notifications on
wfcli notifications persistent
```

`on` watches while at least one `wfgui` connection is open. `persistent` watches whenever
`wfdaemon` is running. The setting is shared with the desktop GUI and persists across restarts.

## Related Guides

- [Data sources and updates](data-sources.md)
- [Query language and watches](query.md)
- [Daemon control](daemon.md)
- [Linux/Proton companion](companion.md)
- [Forma planner](forma-plan.md)
- [MCP server](mcp.md)
