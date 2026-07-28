# Companion And Player Architecture

State ownership is split across three boundaries:

- `wfcompanion` observer owns transient host acquisition: process discovery, Proton prefix,
  DBWIN listener, fallback log cursor, reconnect buffer.
- `wfcompanion` overlay owns visibility, layout, animation, focus gating, and display cache.
- `wfdaemon` owns canonical player snapshots, persistence, subscriptions, and query projection.

Do not move overlay state into the daemon. Do not make the native process persist canonical
player data. A reconnect replays the latest observation for every companion-owned namespace.
Any additional native UI owns its own navigation and display state while consuming the same
daemon data contracts.

## Native Modules

- `main.rs`: process composition and Steam child wrapper.
- `observer.rs`: `/proc` classification, Proton runtime discovery, DBWIN/helper lifecycle, and
  fallback `EE.log` cursor.
- `debug_output.rs`: PE helper launch in the detected Proton prefix and bounded binary record
  decoding. `debug-bridge/debug_output.c` owns the Wine-side DBWIN mapping/events.
- `inventory.rs`: read-only native HTTP-buffer discovery, tolerant account parsing, and typed
  inventory indexes.
- `daemon.rs`: JSON-lines protocol, daemon ensure/reconnect, latest-value replay.
- `capture.rs`: event-triggered Spectacle active-window capture; no continuous recording.
- `relic.rs`: reward trigger debounce, Aleca-derived crop geometry, local Tesseract OCR,
  catalog match scoring, and one daemon relic-context request.
- `focus.rs`: active XWayland window identity and exact Warframe PID/class gate.
- `overlay.rs`: Wayland layer-shell lifecycle, typed scene composition, and click-through input region.
- `painter.rs`: lifetime-safe Blend2D wrapper over the borrowed Wayland SHM buffer.
- `ui_layout.rs`: Taffy Flexbox/Grid tree and named rectangles consumed by the overlay painter.
- `preview.rs`: named mock-overlay registry plus still and optional animated renderers.

Observer work runs off the UI thread. It publishes typed summaries, never raw log content.
Each new collector gets a source namespace instead of extending one untyped document.

Relic scanning first checks expected reward-card bottom-border positions to identify 1-4 player
layouts, matching AlecaFrame's cheap image heuristic. It OCRs only detected normal/legacy crops and
asks the daemon to rank labels against the Market manifest. If border detection or matching fails,
it evaluates every crop layout as fallback. After capture, the shell shows one animated loading
mask while OCR and one batched quote request finish, then complete cards replace it in one update.
If Market lookup fails, recognized cards appear once with unavailable prices. `Forma Blueprint` is
handled locally because it is not tradable. Currency art is loaded from `apps/wfcompanion/assets/`;
provenance is documented beside the files. Dynamic item and component art follows
[`assets.md`](assets.md).

Current overlay uses `smithay-client-toolkit` and `zwlr_layer_shell_v1` directly. It is a
native Wayland `Overlay` layer with no keyboard focus. Passive mode has no pointer input.
Layer-shell margins stay zero; visual HUD spacing is rendered inside the surface so interactive
full-output surfaces have no compositor-level input gap.
Debug-profile builds start with a compact status HUD. It shares the existing layer surface, stays
above contextual scenes, and remains subject to global visibility and the Warframe active-window
gate. Release builds start with the HUD hidden.
After its first contextual scene, hidden mode keeps the full-screen layer surface mapped with a
transparent static buffer. KWin can fail to present a reused layer surface after detach/remap;
keeping the role mapped avoids that path without an idle frame loop or input interception. Relic
loading alone redraws at no more than 30 FPS. Wayland frame callbacks prevent rendering while the
compositor is not ready; monotonic elapsed time determines animation phase, so throttling and
dropped frames do not change animation speed.
The SHM buffer uses `wl_shm::Format::Argb8888`. On little-endian Linux its in-memory bytes are
premultiplied BGRA, matching Blend2D `PRGB32`. `painter` wraps that memory directly through the
Blend2D C API; no channel conversion sits between renderer and Wayland. Contexts remain synchronous
so temporary fontdue A8 glyph masks and decoded icon buffers may be borrowed per draw.
Aspect-contained images use Blend2D's native bilinear scaled blit. Circular component thumbnails
use a transformed Blend2D image pattern to fill circle geometry. Rust computes layout rectangles
but does not resize or mask overlay pixels.
Convert CSS colors through `painter::css_rgba`; never pass copied `[red, green, blue, alpha]`
arrays directly to painter functions.

### Rendering And Damage

Blend2D is the immediate-mode rasterizer, not the retained scene or buffer manager. Taffy computes
layout; Blend2D rasterizes static scene geometry into a premultiplied BGRA cache and dynamic geometry
directly into an available Wayland SHM buffer. A new, resized, or scene-invalidated SHM buffer gets
one complete copy from the static cache and full-buffer damage.

Animation frames must not rebuild or copy the full output. Put unchanging animation background into
the static cache. Before drawing a dynamic frame, restore only its dirty rectangle from that cache,
rasterize only dynamic primitives intersecting it, and pass the same rectangle to
`wl_surface.damage_buffer`. Each reusable SHM buffer is tagged with the static-frame key that
initialized it; a newly allocated fallback buffer cannot use partial restoration until initialized.
If geometry, layout, text, status, scale, or scene data changes, invalidate that key and perform one
full composition.

Blend2D clipping can enforce a dirty boundary, but it does not replace pixel caching: replaying an
immediate-mode scene still submits its layout and overlapping draw operations. Prefer restoring a
small rasterized region for mostly static scenes. Re-rasterize the clipped scene only when measured
performance or highly dynamic content makes that cheaper. Wayland frame callbacks control when to
submit; `wl_buffer.release` controls when a particular SHM buffer may be modified; buffer damage
controls what KWin must repaint. These are separate responsibilities.

Blend2D's built-in multithreaded context is asynchronous. Do not enable it without extending every
borrowed image and glyph-mask lifetime through `Painter::finish`. Current full 2560x1440 relic
composition is below one 30 FPS frame budget and is cached; animation redraws only a small dirty
rectangle. For this workload, synchronous JIT rendering avoids queue overhead and unsafe source
lifetimes.
Visibility requires both user-enabled state and positive Warframe window identity. Live KDE
validation covered fullscreen Warframe plus an unrelated fullscreen application: overlay stayed
above Warframe, unmapped elsewhere, and did not intercept pointer input. See
`docs/developer/overwolf-alecaframe-overlay-research.md` for mechanism and evidence. See
`docs/developer/alecaframe-overlay-catalog.md` for upstream feature behavior and local status.

Contextual scenes temporarily use a full-output transparent layer surface so reward UI can occupy
game-relative coordinates; status mode remains a small top-left surface. Relic preview/live paths
share AlecaFrame 2.6.90's default shell and four-row structure. `ui_layout` mirrors its Flexbox/Grid
tree with Taffy, including content-dependent `space-around` price/marker placement; `overlay` only
paints returned boxes.

`tools/aleca-layout` is a separate development oracle. It loads the ignored AlecaFrame HTML/CSS in
headless Chromium with Overwolf stubs and writes a transparent reference PNG plus JSON containing
overlay-local and absolute screen rectangles, text-run rectangles, and computed styles. Use
`make aleca-layout-setup` once and `make reference-previews` after changing relic layout. Keep these
direct measurements: content changes badge count and therefore price positions. They validate the
Taffy structure; they are not production runtime coordinates.

`wfcompanion preview --all DIR` writes transparent full-output PNGs. The notification preview
composites the status panel at its rendered top-left inset; contextual relic previews already
occupy the full output. `preview --animate TYPE FILE.webm` samples the same scene renderer at its
live frame rate and streams frames to FFmpeg as lossless VP9 with alpha.

Blend2D 0.21.2 and its matching AsmJit 1.21.0 revision are pinned as separate Git submodules under
`apps/wfcompanion/vendor/`. `build.rs` passes the AsmJit checkout through `ASMJIT_DIR`, builds both
statically in Release mode even for Rust debug builds, and links the small C bridge from
`apps/wfcompanion/native/`. Do not replace this with the published Rust crate: that crate contains
a 2019 Blend2D 0.0.1 snapshot and leaves external-image lifetime support disabled.

Run `make native-compile-commands` after changing native dependencies or build flags. It writes
`_build/native/clangd/compile_commands.json` for Blend2D, AsmJit, the C bridge, and the MinGW
debug-output helper. Repository VSCode settings point clangd there and rust-analyzer at the root
Cargo workspace.

## Daemon Modules

- `wfcli_local_api`: supervised AF_LOCAL listener and connection lifecycle.
- `wfcli_local_protocol`: JSON encoding and native protocol version.
- `wfcli_player_service`: source replacement, persistence, subscriptions, game status.
- `wfcli_entity_player`: raw/source entity projection and `data.<path>` access.
- `wfcli_player_query`: adapter into the shared query AST compiler and evaluator.
- `wfcli_market_service`: serialized request ownership, coalescing, TTL, and cancellation.
- `wfcli_market_api` and `wfcli_market_cache`: public HTTP normalization/rate deadline and
  versioned owner-only persistence.
- `wfcli_entity_market` and `wfcli_market_query`: shared AST projection over item metadata and
  cached quotes.

Each `publish` atomically replaces one source namespace. It cannot overwrite other source
namespaces. Persistence uses `player.term` mode `0600`; restart forces persisted
`game.running` false until a connected observer replays current state.

## Local Protocol V5

Transport is newline-delimited JSON over an owner-only Unix stream socket. Client must send
`hello` first. Breaking framing or request semantics requires a protocol increment.
This protocol is versioned independently from the BEAM client/daemon request protocol in
`wfcli_protocol`; their version numbers need not match.

Client operations:

- `hello`: `id`, `protocol`, `client`, `version`, optional `capabilities`.
- `get`: dataset `daemon` or `player`.
- `subscribe`: dataset `player`; initial snapshot is the response.
- `unsubscribe`: prior numeric subscription ID.
- `publish`: dataset `player`, source name, object data.
- `market_resolve`: up to 20 OCR labels and match limit `1..5`; returns ranked English
  item names/slugs with edit distance and confidence. It ensures only the item manifest.
- `relic_context`: up to eight Market slugs; returns reward prices, ducats, set graph,
  ownership, crafted/set-complete state, account currencies, and visible asset requests.
- `relic_recommendations`: era plus optional price refresh; returns up to four owned relics
  ranked by four-player expected best reward.
- `asset_resolve`: up to 64 trusted WFCD or Market image descriptors; returns validated local
  cache paths and content digests.

Server events:

- `dataset`: replacement snapshot for a subscription.
- `command`: optional overlay diagnostic command.

Messages are capped at 1 MiB. Socket parent is mode `0700`; socket is mode `0600`.
This authenticates the local OS user, not an individual binary. Treat all same-user clients
as trusted. Keep player data out of Erlang distribution and terminal-formatting contracts.
See [`player-data.md`](player-data.md) for the account payload, collector, and derived
inventory or mastery boundary.

## Lifecycle

Steam launch mode is the normal companion lifecycle. It makes companion Warframe's ancestor for
read-only inventory collection and exits companion with the game. Standalone mode is retained for
diagnostics and overlay development.

Companion invokes `wfcli daemon ensure` only when the socket is absent or protocol recovery is
needed. `ensure` preserves current daemon idle policy. Each compatible `wfcompanion` connection
holds daemon external activity until disconnect, even when the game is stopped and no request is
running. Player fields such as `game.running` are observations, not lifecycle leases; stale
persisted data must never pin the daemon. Connection loss removes subscriptions, but persisted
data remains.

Steam launch mode gives companion host process Steam/Proton loader variables even though
companion and daemon are native host binaries. Companion removes those variables when invoking
`wfcli`; `wfcli_client` removes them again before starting release. Do not let `LD_PRELOAD`,
`LD_LIBRARY_PATH`, or Steam runtime library paths reach ERTS helper programs. Correlated market
requests replay once after connection loss so daemon recovery can finish an active relic scene.

Build changes to Erlang modules still use normal daemon build-fingerprint hot update. Native
protocol compatibility is separate because `wfcompanion` is not a BEAM client.

## Extension Rules

1. Acquire data in native collector without blocking overlay or socket loops.
2. Normalize into a documented source object; avoid raw memory/log dumps.
3. Publish only on meaningful change or bounded progress intervals.
4. Add player query and focused CLI tests when fields become user-visible.
5. Keep terminal rendering in `wfcli`; overlay rendering stays native.
6. Put shared market fetch/cache and item resolution in `wfdaemon`; desktop and overlay
   consume one typed contract.
7. Keep desktop navigation and account workflows out of overlay code.

## Market Boundary

AlecaFrame does not fetch one public Warframe Market endpoint per displayed item. Its client
normalizes names to market slugs, batches requested slugs to AlecaFrame's own
`/prices/priceData` endpoint, and caches returned values for 15 minutes. Returned `post` and
`insta` values are consumed as sell and immediate-buy prices; rank-specific minima and volume
are supplemental fields.

`wfcli` must not depend on that private aggregator. `wfdaemon` owns Warframe Market API access,
the identifying user agent, global rate limiter, request coalescing, item manifest, quote cache,
and explicit quote semantics such as `lowest_sell` and `highest_buy`. `wfcompanion` sends item
identities and retains only a presentation cache. CLI commands and `dataset=market` consume the
same daemon service. Do not call the market API from overlay or terminal formatting code.

Current implementation uses public `/v2/items` plus `/v2/orders/item/{slug}/top`, fixed to
PC, cross-play, and English. `lowest_sell` is the minimum returned sell order; `highest_buy`
is the maximum returned buy order. Reward ducats come directly from `/v2/items`, so they need no
additional request. Successful manifest and quotes persist in owner-only
`market.term`; stale values remain usable when refresh fails. Catalog query ensures only the
manifest. Live quote expansion requires `wfcli market` or local `market_quote` and rejects
unbounded broad matches.
