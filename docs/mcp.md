# MCP Server

`wfcli mcp` gives MCP hosts structured access to the persistent `wfdaemon` used by the terminal
client. The host starts one short-lived stdio process; that process connects to or starts the
shared daemon.

## Register

Build the desired environment, then register its `wfcli` executable:

```bash
make prod-erlang
codex mcp add wfcli -- /absolute/path/to/wfcli/prod/bin/wfcli mcp
```

Development registration can use `dev/bin/wfcli mcp`. Standard output contains only
newline-delimited JSON-RPC messages; diagnostics use standard error.

## Tools

- `query`: runs the shared query language. Results are unlimited unless `limit` is supplied.
- `forma_plan`: queues the daemon-owned planner and returns canonical data.
- `daemon_status`: starts the daemon if needed and returns queue, cache, protocol, and build state.
- `update_knowledge`: refreshes selected daemon-managed metadata and WFCD caches.

Tool calls are monitor-owned. MCP cancellation or host exit terminates the adapter worker;
`wfcli_client` then releases the corresponding queued or running daemon request.

## Resources

- `wfcli://datasets`: query datasets and descriptions.
- `wfcli://query-language`: compact grammar and examples.
- `wfcli://schema/worldstate`: normalized fields and type-specific views.
- `wfcli://daemon/status`: live daemon status as JSON.

`wfcli` owns MCP framing and JSON conversion. Fetching, persistence, query evaluation, and Forma
planning remain in `wfdaemon`. The stdio process opens no network listener; Erlang distribution is
bound to loopback and protected by the normal distribution cookie.
