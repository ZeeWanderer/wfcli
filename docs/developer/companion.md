# Companion Architecture

Ownership:

- `wfcompanion` observer owns process discovery, Proton integration, DBWIN,
  fallback log state, capture, and OCR.
- `wfcompanion` overlay owns scenes, interaction, focus gating, layout,
  rendering, and display caches.
- `wfdaemon` owns canonical player snapshots, persistence, queries, Market
  access, asset resolution, and relic calculations.

Overlay state stays native. Canonical player state stays in the daemon.

## Native Modules

- `observer.rs`, `debug_output.rs`: process and Proton discovery, DBWIN helper,
  and fallback `EE.log` cursor.
- `inventory.rs`: read-only account-buffer discovery, tolerant parsing, and
  typed indexes.
- `daemon.rs`: local JSON-lines client, reconnect, replay, and request routing.
- `capture.rs`, `relic.rs`: event-triggered capture, crop detection, OCR, and
  relic scene construction.
- `focus.rs`: exact Warframe window and process gate.
- `overlay/runtime.rs`: layer shell, SHM buffers, frame callbacks, input, focus,
  and damage.
- `overlay/renderer.rs`: fonts, static frame cache, dispatch, and previews.
- `overlay/scene.rs`: top-level scene and presentation state.
- `overlay/screens/`: complete screen painting and hit regions.
- `ui/layout.rs`: named Taffy tree and resolved geometry.
- `ui/geometry.rs`: rectangles, hit regions, and render output.
- `painter.rs`: text, image, and shape operations.
- `painter/blend2d.rs`: safe synchronous boundary over the Blend2D C bridge.

Observer work runs off the UI thread. New collectors publish a separate source
namespace instead of extending one untyped payload.

## Layout

`UiTree<K>` is the semideclarative layout layer. Screens declare named leaves,
rows, columns, grids, stacks, dimensions, spacing, alignment, and clipping.
Taffy resolves absolute and content bounds; screen code never walks parent
origins or computes draw rectangles.

Taffy does not paint. Each screen consumes named bounds and issues exact
Blend2D operations. This preserves predictable draw order and keeps visual
logic beside its screen. Add shared components only after two screens need the
same composition.

Each screen owns:

- typed display model and presentation state;
- top-level `UiTree`;
- painting and animation;
- hit targets;
- preview fixture and pixel tests.

Screens do not import sibling screens. `scene.rs` dispatches them. Runtime uses
`ScreenOutput` from the cached render and has no screen-specific geometry.

Use function-specific borrowed input structs when a call carries one semantic
operation with many fields. Return normal Rust values. Output pointers belong
only at FFI boundaries. Thin Blend2D wrappers use reusable image, rectangle,
circle, and mask value types while preserving the underlying C ABI.

## Rendering

The Wayland surface uses `wl_shm::Format::Argb8888`. On little-endian Linux its
bytes are premultiplied BGRA, matching Blend2D `PRGB32`.

Static scene geometry is rasterized once into a cached frame. Animation:

1. restores its dirty rectangle from the static cache;
2. draws only dynamic primitives;
3. submits the same rectangle with `wl_surface.damage_buffer`.

New, resized, or invalidated buffers receive one full static-frame copy.
`wl_buffer.release` controls buffer reuse; frame callbacks control submission
timing; damage controls compositor repainting.

Blend2D remains synchronous because icons and fontdue glyph masks are borrowed
for each draw call. Its asynchronous multithreaded context requires owned
source lifetimes through `Painter::finish` and is not useful for the current
cached workload.

Passive mode has no pointer region. Interactive mode enables only screen
reported hit regions. Layer-shell margins remain zero so a persistent pointer
position cannot fall into an uncapturable compositor gap.

## Relic Pipeline

Reward flow:

1. Deduplicate reward debug events.
2. Capture after game UI stabilization.
3. Detect one-to-four card geometry.
4. OCR reward-name crops.
5. Resolve labels and one quote batch through the daemon.
6. Resolve ducats, vault state, player state, set graph, and visible assets.
7. Render complete cards.

Selection flow:

1. Detect selection open/close events.
2. OCR only the era selector.
3. Ask the daemon to rank owned relics.
4. Render immediately from cached data and refresh prices asynchronously.

`Forma Blueprint` is local because it is not tradable. Dynamic image behavior
is documented in [`assets.md`](assets.md); inventory indexing is documented in
[`player-data.md`](player-data.md).

## Local Protocol V5

Transport is newline-delimited JSON over an owner-only Unix socket. Client must
send `hello` first. This version is independent of the BEAM client protocol.

Requests:

- `get`, `subscribe`, `unsubscribe`
- `publish`
- `market_resolve`
- `relic_context`
- `relic_recommendations`
- `asset_resolve`

Events:

- `dataset`: replacement subscription snapshot
- `command`: overlay diagnostic command

Messages are capped at 1 MiB. Socket parent mode is `0700`; socket mode is
`0600`. Same-user clients are trusted. Player data does not enter Erlang
distribution or terminal formatting contracts.

Breaking framing or request semantics requires a protocol increment.

## Lifecycle

Launch mode keeps companion tied to the Steam child and gives the inventory
collector ptrace ancestry. Standalone mode is managed by the CLI.

Companion starts or reconnects to the daemon without passing Proton loader
variables into BEAM. Reconnect replays latest observations for every owned
namespace. An active companion connection keeps an implicitly started daemon
alive.

Debug builds show the compact HUD by default. Release builds start with it
hidden. Hidden mode keeps the transparent layer surface mapped after its first
scene because KWin may not present a detached and reused layer role reliably.
No idle render loop runs.

## Development

```bash
make dev-companion
make test-companion
make previews
make native-compile-commands
```

`make native-compile-commands` updates clangd metadata for Blend2D, AsmJit, the
C bridge, and MinGW helper.

AlecaFrame reference layouts:

```bash
make aleca-layout-setup
make reference-previews
```

Setup downloads the latest official OPK and prepares headless Chromium.
Reference PNG and DOM geometry files are written under ignored
`previews/reference/`. See [`tools/aleca-layout/README.md`](../../tools/aleca-layout/README.md).

Upstream behavior and safety evidence:

- [`alecaframe-overlay-catalog.md`](alecaframe-overlay-catalog.md)
- [`overwolf-alecaframe-overlay-research.md`](overwolf-alecaframe-overlay-research.md)
