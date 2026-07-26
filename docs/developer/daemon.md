# Daemon Architecture

`wfdaemon` shares expensive and rate-sensitive work between independent clients. It owns network
fetching, decoded worldstate snapshots, catalog indexes, query execution, player state, market
access, Forma planning, and watches. `wfcli` owns arguments, MCP framing, and output formatting.
`wfcompanion` owns native observation and overlay state.

## Lifecycle And Transport

- Clients connect to fixed node `wfdaemon@localhost` through `wfcli_client`.
- Distribution binds to IPv4 loopback and uses the invoking user's Erlang cookie.
- OTP 29 dynamic hidden client nodes do not listen for incoming distribution connections.
- Client/daemon requests use typed `gen_server:call({wfcli_daemon, Node}, Request, Timeout)`.
- Production code contains no direct `rpc:*`, `erpc:*`, or remote `spawn*` evaluation.
- Concurrent startup tolerates another client winning the race.
- Implicit startup uses idle shutdown; explicit startup reapplies persistent or requested idle
  policy to a running daemon.
- Watches, queued work, and connected companions hold an activity lease.
- Forma plans are serialized because one planner already uses internal CPU parallelism.

The daemon changes its working directory to `$XDG_STATE_HOME/wfcli` during application startup.
This keeps crash dumps and relative runtime state valid while a staged release directory is
replaced.

## Build Identity

Protocol version describes request compatibility. Artifact flavor (`dev` or `prod`) prevents one
environment from starting or updating the other. Build identity is SHA-256 over sorted module
names and BEAM MD5 values for `wfcore` plus `wfdaemon`.

Handshake recovery:

1. Compare protocol, flavor, and build identity.
2. Hot-load a compatible stale build from the calling artifact.
3. Repeat handshake.
4. Stop the old daemon and start the requested release if compatibility is still not established.

Older clients do not downgrade newer daemon protocols.

## Requests And Cancellation

One-off commands submit a monitored one-shot subscription. The daemon queues work, sends exactly
one `{wfcli_daemon, Ref, Reply}` message, and removes the request. Persistent watches use the same
shape but stay registered.

The local client relay is monitored across distribution. Closing a terminal, killing a client, or
MCP cancellation produces `DOWN`; queued or active query, market, catalog, and planning work is
released without polling. Shared worldstate fetches may continue when other clients or cache
refresh still need them.

## Worldstate And Catalogs

`wfcli_worldstate_service` caches decoded snapshots by cache path and indexes by normalization
options. With active watches, one global timer polls worldstate; every due watch evaluates against
the same parsed snapshot. Fetch failure retains the last good snapshot and marks delivery stale.

`wfcli_exports_store` serializes official export and Codex queries. Catalog keys include source
directory, selected files, entity kind, modification time, and size. `wfcli_source_manager`
prepares missing managed data. Explicit custom source directories are never modified.

Query text reaches the daemon uncompiled. `wfcli_query_parse` builds the AST; entity modules expose
typed fields and retain raw data paths where a parser has not added semantics.

## Market And Player Data

`wfcli_market_service` owns Warframe Market manifests, quote TTLs, persistence, coalescing, and its
daemon-wide request limiter. `wfcli_market_api` handles wire normalization;
`wfcli_market_cache` handles versioned atomic persistence.

`wfcli_player_service` owns canonical local observations by source namespace. `wfcli_local_api`
accepts owner-only Unix socket clients, including `wfcompanion`, and removes subscriptions on
disconnect. Persisted observations do not keep the daemon alive.

## Supervision

`wfcli_sup` uses `one_for_one` permanent children for daemon protocol, worldstate, catalogs,
source management, query, Forma, player, market, and local API services. Queue workers are
monitored; worker failure becomes a request error while the owner survives. Systemd adds VM-level
restart for explicitly installed user services.

## Hot Update

Both explicit and automatic updates use `wfcli_hot_update`:

1. Read and validate `wfcore` and `wfdaemon` BEAM bundles.
2. Reject duplicate module identities.
3. Skip unchanged modules by BEAM MD5.
4. Suspend affected registered stateful services.
5. Load changed modules, invoke `code_change/3`, and resume services.
6. Restart the local socket API when its accept loop cannot leave old code.
7. Commit the new build identity only after successful load and migration.

Each staged root contains `BUILD_ID`. The daemon checks it every five seconds and reads BEAMs from
its stable update root. Repository builds use `dev/` or `prod/`; a Homebrew Cellar install resolves
to its stable `opt/<formula>` link. This supports same-version updates without a client request.

`wfcli daemon update` sends the same typed hot-update request explicitly. No updater module is
bootstrapped through remote evaluation. Standard versioned `.appup`/relup artifacts remain the
path for module deletion and complex release ordering via `daemon update --release RELEASE`.

## Ownership Rule

Daemon modules return data and never print or halt. CLI modules parse options, submit typed
requests, and render replies. MCP modules translate JSON schemas into the same requests. `wfcore`
contains only shared contracts and helpers; it owns no service state.
