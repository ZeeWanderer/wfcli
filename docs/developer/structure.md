# Project Structure

The repository has three executable components and one process-free OTP library.

## `wfcli`

`apps/wfcli/src/` is the short-lived user and integration interface:

- `wfcli_cli`, `wfcli_help*`, and `wfcli_*_cli`: arguments, help, exit status, requests.
- `wfcli_client`: loopback distribution, daemon lifecycle, compatibility, requests,
  subscriptions, and cancellation.
- `wfcli_autostart`: flavor-specific systemd user units.
- `wfcli_mcp_*`: stdio JSON-RPC, MCP schemas, resources, and request translation.
- `wfcli_*_format`, `wfcli_*_presentation`, `wfcli_table`, `wfcli_tty`: output only.
- `wfcli_forma_plan`, `wfcli_visualize`, `wfcli_forma_visualizer`: planner result output.

CLI modules do not fetch, persist, compile query ASTs, normalize worldstate, or run the Forma
solver. MCP is a `wfcli mcp` interface, not a separate OTP application.

## `wfdaemon`

`apps/wfdaemon/src/` owns persistent state and domain work:

- `wfcli_sup`, `wfcli_daemon`, `wfcli_hot_update`: supervision, request protocol, lifecycle.
- `wfcli_worldstate_service`, `wfcli_exports_store`, `wfcli_source_manager`,
  `wfcli_query_service`, `wfcli_forma_service`, `wfcli_market_service`: serialized queues and
  shared caches.
- `wfcli_worldstate*`, `wfcli_exports*`, `wfcli_knowledge*`, `wfcli_resolve*`: fetching,
  persistence, normalization, and catalogs.
- `wfcli_query_parse`, `wfcli_entity_query`, and `wfcli_entity_*`: query compilation and
  evaluation.
- `wfcli_player_service`, `wfcli_local_api`: canonical local player state and native-client
  transport.
- `wfcli_forma_config`, `wfcli_forma_model`, `wfcli_forma_planner`: planner domain.

Daemon replies are data maps. Daemon modules never print, halt, or choose terminal layouts.
Planner and query execution remain daemon-owned so concurrent clients cannot duplicate expensive
work.

## `wfcore`

`apps/wfcore/src/` is a normal OTP library application with no application callback, supervisor,
or process. It gives each BEAM module one owner while allowing both executables to depend on it:

- `wfcli_protocol`, `wfcli_build`, `wfcli_paths`
- `wfcli_*_schema`
- `wfcli_text`, `wfcli_time`, `wfcli_polarity`
- `wfcli_data_extract`, `wfcli_worldstate_diff`

Compiling these files separately into `wfcli` and `wfdaemon` creates duplicate BEAM ownership,
breaks xref, and makes debugger code paths ambiguous. Keep only stable cross-application contracts
and value helpers here.

## `wfcompanion`

`apps/wfcompanion/` is a standalone Rust process:

- `observer`: `/proc`, Proton prefix, DBWIN helper, and `EE.log` acquisition.
- `daemon`: owner-only Unix socket transport and reconnect replay.
- `focus`: positive active-window identity for the observed Warframe process.
- `relic`: trigger, capture, OCR, item resolution, and market requests.
- `overlay`, `painter`, `ui_layout`: Wayland surface, Blend2D rendering, and Taffy layout.
- `preview`: registered still and animated overlay previews.
- `main`: process composition and Steam wrapper mode.

The companion owns native window and overlay state. It publishes normalized observations to the
daemon and requests shared data from it.

## Runtime Layout

- Rebar3 and Cargo output: `_build/`
- Download and compiler caches: `.cache/`
- Development stage: `dev/`
- Production stage: `prod/`
- Package archives: `releases/`
- Managed user data: `$XDG_CACHE_HOME/wfcli`, `$XDG_STATE_HOME/wfcli`
- Tests and fixtures: `apps/wfcli/test/`, `apps/wfcompanion/tests/`
- Disposable upstream research: ignored `research/`

## Change Placement

New worldstate type: project/index in `wfdaemon`, extend `wfcore` schema only when both apps need
the contract, add CLI presentation, then add fixture/output tests.

New daemon feature: use an existing queue unless independent state or failure isolation requires a
new supervised worker. Return data-only replies and implement `code_change/3` for stateful changes.

New CLI command: parse options, submit a typed request, render the reply. Query text stays opaque
until the daemon parses it.

New MCP operation: translate a schema into an existing typed daemon request. Add a daemon request
only when no suitable operation exists.
