# Project Structure

The repository has four executable components and one process-free OTP library.

## `wfcli`

`apps/wfcli/src/` is the short-lived user and integration interface:

- `command/`: arguments, help, completion, exit status, and request construction.
- `client/`: daemon transport, lifecycle, compatibility, autostart, and companion control.
- `mcp/`: stdio JSON-RPC, MCP schemas, resources, and request translation.
- `output/`: formatters, presentation, table layout, and terminal handling.
- `forma/`: planner result serialization and HTML/SVG visualization.

CLI modules do not fetch, persist, compile query ASTs, normalize worldstate, or run the Forma
solver. MCP is a `wfcli mcp` interface, not a separate OTP application.

## `wfdaemon`

`apps/wfdaemon/src/` owns persistent state and domain work:

- `runtime/`: daemon lifecycle, hot update, local transport, and generic cache state.
- `worldstate/`: snapshot fetch, indexing, projection, watches, and identifier resolution.
- `catalog/`: PublicExport/WFCD updates, source preparation, exports, and knowledge.
- `query/`: query parsing, entity adapters, sorting, and execution.
- `market/`: market cache/API, relic context, recommendations, and assets.
- `player/`: canonical player dataset and queries.
- `forma/`: serialized planner queue, search, rules, assignment, config, and model.

Daemon replies are data maps. Daemon modules never print, halt, or choose terminal layouts.
Planner and query execution remain daemon-owned so concurrent clients cannot duplicate expensive
work.

## `wfcore`

`apps/wfcore/src/` is a normal OTP library application with no application callback, supervisor,
or process. It gives each BEAM module one owner while allowing both executables to depend on it:

- `contract/`: protocol, build/path identity, and shared schemas.
- `value/`: process-free text, time, polarity, extraction, and diff helpers.

Compiling these files separately into `wfcli` and `wfdaemon` creates duplicate BEAM ownership,
breaks xref, and makes debugger code paths ambiguous. Keep only stable cross-application contracts
and value helpers here.

## `wfcompanion`

`apps/wfcompanion/` is a standalone Rust process:

- `game_observer`: Warframe process/build identity, read-only memory, and typed evidence.
- `observer`: collector lifecycle and observation policy.
- `daemon`: owner-only Unix socket transport and reconnect replay.
- `focus`: positive active-window identity for the observed Warframe process.
- `relic`: trigger, capture, OCR, item resolution, and market requests.
- `overlay`, `painter`, `ui`: Wayland surface, Blend2D rendering, and Taffy layout.
- `preview`: registered still and animated overlay previews.
- `main`: process composition and Steam wrapper mode.

The companion owns native window and overlay state. It publishes normalized observations to the
daemon and requests shared data from it.

`wfinspect` is a separate research and diagnostic executable built from the companion crate. It invokes
observer collectors explicitly without inheriting companion lifecycle or polling policy. Cache,
build-adapter, DBWIN, GEP, replay, script, and local-protocol diagnostics share companion parsers
rather than research copies. Generic Ghidra exporters live under `tools/wfinspect-ghidra/`;
build-specific projects and evidence remain ignored research data.

Its read-only research-memory layer opens either `/proc/PID/mem` or bounded capture blocks behind
the same query functions. Live and captured UI text, references, pointer paths, and typed probes
therefore use one implementation. Snapshot commands emit JSON, watches emit NDJSON, and raw byte
commands keep standard output free of metadata.

Warframe Luau source reconstruction is a separate pinned toolchain stage under
`tools/wf-luau-decompiler/`. `wfinspect` owns cache extraction and build-specific normalization;
the helper owns only normalized-bytecode reconstruction and exposes file/standard-input plus JSON
diagnostics. Staged builds place both executables together so helper discovery needs no config.

Oodle decoding uses the separate `libexec/unoodle` helper. `scripts/build-oozextract`
pins its registry archive and checksum, builds with the caller's Rust flags, and
stages its source and license under `share/licenses/oozextract/`.

## `wfgui`

`apps/wfgui/` is the native C++ Qt Widgets desktop client:

- `daemon_client`: local JSON-lines transport, daemon startup, reconnect, and request correlation.
- `relic_model`: typed relic list, filtering, and asset-path updates.
- `relic_grid_widget`: virtualized relic-card delegate and interaction routing.
- `player_item_model`: shared Inventory and Mastery data/filter model.
- `player_item_grid_widget`: responsive model/view card rendering and visible-asset requests.
- `app_controller`: per-view cached metadata, price, asset, loading, and error state.
- `relic_card_layout`: responsive card constraints shared by rendering and tests.
- `main_window` and view widgets: navigation and desktop rendering.

CMake presets use a project vcpkg manifest and LLVM/libc++ overlay triplet. Build it separately
with `make gui`; `make dev` and `make prod` include the matching GUI build.

## Runtime Layout

- Rebar3 and Cargo output: `_build/`
- Download and compiler caches: `.cache/`
- Development stage: `dev/`
- Production stage: `prod/`
- Package archives: `releases/`
- Managed user data: inspect with `wfcli paths`
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
