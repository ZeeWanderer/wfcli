# Linux/Proton Companion

`wfcompanion` observes a local Warframe process, publishes player data to `wfdaemon`, and renders
contextual Wayland overlays. It does not inject into Warframe, Wine, or the graphics pipeline.

Current overlays cover relic rewards and relic selection:

- Reward cards show recognized item names, Warframe Market prices, ducats, vault state, ownership,
  crafted state, set components, and set value.
- Relic recommendations rank owned relics for the selected era by expected platinum and ducats.

## Requirements

Runtime:

- KDE Plasma on Wayland
- `kscreen-doctor` and Spectacle
- Tesseract 5 with English `eng.traineddata`
- a built `wfcli`/`wfdaemon` environment

Build:

```bash
git submodule update --init
make companion
```

Development and production binaries are staged as:

```text
dev/bin/wfcompanion
prod/bin/wfcompanion
```

`wfcompaniond` points to the development binary and displays a compact diagnostic HUD while
Warframe is active. Production `wfcompanion` starts with that HUD hidden.

## Steam Launch Mode

Launch mode is preferred. It starts companion with Warframe, stops it when Warframe exits, and
gives the read-only player-data collector the process relationship required by normal Linux
ptrace restrictions.

In Steam:

1. Open **Library > Warframe > Properties**.
2. Select **General**.
3. Set **Launch Options** to an absolute companion path:

```bash
/absolute/path/to/wfcli/prod/bin/wfcompanion launch -- %command%
```

Use `dev/bin/wfcompanion` instead when testing a development build. Steam may not inherit the
shell's `PATH`, so an absolute path is required.

Keep existing launch wrappers after `--`. For example:

```bash
/absolute/path/to/wfcli/prod/bin/wfcompanion launch -- gamemoderun %command%
```

Launch Warframe normally from Steam. Check the connection from another terminal:

```bash
wfcli companion status
```

Companion starts or reconnects to `wfdaemon` without passing Steam/Proton loader variables into
the Erlang runtime.

## Standalone Mode

Standalone mode runs companion as a detached user service:

```bash
wfcli companion start
wfcli companion status
wfcli companion restart
wfcli companion stop
```

It is useful for diagnostics and overlay development. Launch mode is required for player
inventory collection on systems enforcing the usual ptrace ancestry rule.

Visibility controls apply to the running companion:

```bash
wfcli companion show
wfcli companion hide
wfcli companion hud show
wfcli companion hud hide
```

`show` and `hide` control the whole overlay, including automatic contextual scenes. `hud` controls
only the diagnostic panel. Overlay pixels appear only while Warframe is the active recognized
game window.

## Interaction

Press `Ctrl+Tab` while a relic overlay is visible to enter or leave interaction mode. KDE may ask
for global-shortcut permission on first use.

Interaction mode:

- captures pointer input only over the overlay;
- allows closing and scrolling relic recommendations;
- returns pointer control after another `Ctrl+Tab`, an outside click, scene closure, or Warframe
  focus loss.

Reward cards are display-only. Passive overlays are click-through.

## How Detection Works

Companion receives Warframe debug output through a small Wine DBWIN helper. `EE.log` is a delayed
fallback when DBWIN is unavailable.

For relic rewards, companion waits for the game UI, captures the Warframe window, detects the
one-to-four-player card layout, and runs local Tesseract OCR over reward names. The daemon resolves
items, batches Warframe Market quotes, supplies catalog and player metadata, and resolves required
image assets. Screenshots are deleted after decoding.

For relic selection, companion captures only the era selector. The daemon ranks relics from the
cached player inventory, WFCD reward tables, and Warframe Market quotes.

## Diagnostics

Inspect game, Proton, helper, and daemon detection:

```bash
wfcli companion probe
wfcli companion logs
```

Capture through the same path used by relic recognition:

```bash
wfcli companion screenshot ./capture.png
wfcli companion screenshot --target screen ./screen.png
```

Run OCR against a saved image or a new capture:

```bash
wfcli companion relic-ocr ./capture.png
wfcli companion relic-ocr --target screen
wfclid companion relic-ocr apps/wfcompanion/tests/fixtures/relic_rewards_4p_2560x1440.jpg
```

Run the complete saved-image reward pipeline:

```bash
dev/bin/wfcompanion --relic-screenshot ./capture.png
```

Executable overrides:

- `WFCOMPANION_SPECTACLE`
- `WFCOMPANION_TESSERACT`
- `WFCOMPANION_DEBUG_BRIDGE`
- `WFCOMPANION_CAPTURE_DIR`

## Overlay Previews

Render mock scenes onto transparent images:

```bash
wfcli companion preview --list
wfcli companion preview relic-rewards
wfcli companion preview relic-rewards /tmp/relic-preview.png
wfcli companion preview --all
make previews
```

`make previews` renders at 2560x1440. Override it with `PREVIEW_SIZE=WIDTHxHEIGHT`. Direct preview
commands accept `WFCOMPANION_PREVIEW_SIZE=WIDTHxHEIGHT`.

Animated previews require FFmpeg:

```bash
wfcli companion preview --animate relic-loading
wfcli companion preview --animate-all
make preview-videos
```

## Logs And Captures

The bounded JSONL incident log is:

```text
$XDG_STATE_HOME/wfcli/wfcompanion.log
```

It falls back to `~/.local/state/wfcli/wfcompanion.log`. `WFCOMPANION_LOG` overrides the path.
The log rotates once at 1 MiB and excludes raw debug text, `EE.log` lines, screenshots, and player
payloads.

Automatic captures use `$XDG_CACHE_HOME/wfcli/captures`, falling back to
`~/.cache/wfcli/captures`, and are removed after use.

## Player Dataset

Companion publishes local observations through the daemon's owner-only Unix socket:

```bash
wfcli player
wfcli player source=game
wfcli query 'dataset=player data.phase=game'
wfcli query 'dataset=player source=inventory'
```

Namespaces:

- `game`: stopped, launcher, or game phase; process and Proton paths.
- `collector`: DBWIN and `EE.log` observation counters.
- `inventory`: account payload, typed inventory/mastery indexes, and preserved unknown fields.

Player data remains local in the daemon cache. The socket defaults to
`$XDG_RUNTIME_DIR/wfcli/wfdaemon.sock`, has mode `0600`, and can be overridden with
`WFCLI_DAEMON_SOCKET`.

Implementation, protocol, rendering, and safety details live in
[Companion And Player Architecture](developer/companion.md).
