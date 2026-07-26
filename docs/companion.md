# Linux/Proton Companion

`wfcompanion` observes Warframe on a Linux host, publishes local observations to `wfdaemon`, and
renders a native Wayland overlay. The overlay is click-through unless interaction mode is active.
It does not inject into Warframe, Wine, or the graphics pipeline.

The relic overlay is triggered by Warframe debug output. Companion captures the active Warframe
window, recognizes reward labels with local Tesseract OCR, resolves labels through daemon-owned
catalog data, and displays ducats plus prices from the daemon's shared Warframe Market service. `EE.log`
tailing provides a delayed fallback when the Wine DBWIN listener is unavailable.

The relic-selection overlay uses the same event streams. It reads the visible era label, asks the
daemon to rank owned relics by expected best reward in a four-player squad, and closes when the
selection screen closes. It has no fixed lifetime because the selection screen may remain open
indefinitely. Missing cached Market quotes display as `--`; recommendation rendering does not
block on network price refresh.

## Interaction Mode

While a relic-selection or relic-reward overlay and Warframe are both active, press `Ctrl+Tab` to
enter or leave interaction mode. The first use may open the desktop shortcut permission dialog.
Interaction mode captures pointer input across the overlay surface so the compositor can take the
pointer from Proton's relative-pointer lock. Click the close button to dismiss relic suggestions,
or click outside interactive content to return pointer control to the game. Pressing `Ctrl+Tab`
again, losing Warframe focus, or closing the current scene also leaves interaction mode. Reward
cards remain display-only.

The shortcut uses the XDG Global Shortcuts portal rather than an X11 key grab. Companion creates a
hidden desktop identity at
`$XDG_DATA_HOME/applications/io.github.zeewanderer.wfcompanion.desktop`, falling back to
`~/.local/share/applications`, so Steam launch-wrapper mode is registered as `wfcompanion` rather
than Steam.

Automatic captures use `$XDG_CACHE_HOME/wfcli/captures`, or `~/.cache/wfcli/captures` when
`XDG_CACHE_HOME` is unset. Captures are deleted after decoding. Screenshots and raw game-log lines
are not persisted by normal operation.

## Build

```bash
make companion
dev/bin/wfcompanion --help
```

Runtime requirements:

- KDE Plasma on Wayland, KScreen, and Spectacle
- Tesseract 5 with English `eng.traineddata`
- an assembled `wfdaemon` release and `wfcli` client

`WFCOMPANION_SPECTACLE`, `WFCOMPANION_TESSERACT`, and `WFCOMPANION_DEBUG_BRIDGE` override
nonstandard executable locations. `WFCOMPANION_CAPTURE_DIR` overrides the shared capture path.

The development executable `wfcompaniond` displays a persistent diagnostics HUD while Warframe is
active. It shows daemon connectivity, detected game state, DBWIN and `EE.log` counters, and current
relic scene. Production `wfcompanion` only renders requested and contextual scenes.

## Standalone Mode

Run companion as a detached process through `wfcli`:

```bash
./wfcli companion start
./wfcli companion status
./wfcli companion show
./wfcli companion hide
./wfcli companion hud show
./wfcli companion hud hide
./wfcli companion restart
./wfcli companion stop
```

`show` and `hide` enable or disable the entire overlay, including automatic contextual scenes, for
the current companion process. `hud show` and `hud hide` control the diagnostic info panel without
changing contextual-scene behavior. Production starts with the HUD hidden; development starts
with its compact debug HUD shown. Restarting the companion restores these defaults. Visibility
also requires Warframe to be the active recognized game window; unrelated applications do not
receive the surface.

Companion starts an absent daemon through `wfcli daemon ensure`. Its local connection keeps an
idle-policy daemon active. Disconnecting starts the daemon's normal idle countdown when no other
work remains.

## Steam Launch Wrapper

Close Steam before changing launch options:

```bash
./wfcli companion install --dry-run
./wfcli companion install
./wfcli companion uninstall --dry-run
./wfcli companion uninstall
```

The installed wrapper starts companion with Warframe and exits it when Warframe exits. Use either
standalone mode or wrapper mode for a game session. `wfcli companion stop` controls detached
standalone instances; wrapper lifetime follows the game process.

## Diagnostics

Inspect process and Proton detection without starting the overlay:

```bash
./wfcli companion probe
```

Capture through the same Spectacle path used by relic recognition:

```bash
./wfcli companion screenshot ./capture.png
./wfcli companion screenshot --target screen ./screen.png
```

Run OCR against an existing image or a new capture:

```bash
./wfcli companion relic-ocr ./capture.png
./wfclid companion relic-ocr apps/wfcompanion/tests/fixtures/relic_rewards_4p_2560x1440.jpg
./wfcli companion relic-ocr --target screen
```

Render mock scenes onto transparent images sized to the current primary output:

```bash
./wfcli companion preview --list
./wfcli companion preview relic-rewards
./wfcli companion preview relic-rewards /tmp/relic-preview.png
./wfcli companion preview --all
make previews
```

Default preview output is the ignored repository-local `previews/` directory. `make previews`
renders at 2560x1440; set `PREVIEW_SIZE=WIDTHxHEIGHT` to override it. Direct preview commands can
use `WFCOMPANION_PREVIEW_SIZE=WIDTHxHEIGHT` without querying KScreen.
Animated development previews use FFmpeg:

```bash
./wfcli companion preview --animate relic-loading
./wfcli companion preview --animate-all
make preview-videos
```

For a complete overlay and market-resolution test with a saved image:

```bash
dev/bin/wfcompanion --relic-screenshot ./capture.png
```

## Incident Log

```bash
./wfcli companion logs
```

Companion writes bounded JSONL records to `$XDG_STATE_HOME/wfcli/wfcompanion.log`, or
`~/.local/state/wfcli/wfcompanion.log` when `XDG_STATE_HOME` is unset. `WFCOMPANION_LOG`
overrides the path. The log rotates once at 1 MiB and suppresses repeated identical connection
errors for 60 seconds.

Records cover lifecycle, daemon connection, debug-listener state, capture/OCR selection, and
failures. Debug text, `EE.log` lines, and screenshots are excluded.

## Player Dataset

Companion publishes typed local observations through the daemon's owner-only Unix socket:

```bash
./wfcli player
./wfcli player source=game
./wfcli query 'dataset=player data.phase=game'
./wfcli query 'dataset=player source=collector'
```

Published namespaces:

- `game`: stopped, launcher, or game phase; host PID; Proton compat-data path; `EE.log` path
- `collector`: counts and timestamp for debug-output and fallback `EE.log` lines observed after
  companion startup
- `inventory`: latest versioned account observation, typed inventory/mastery indexes, and raw
  unknown fields collected by the read-only Proton helper

Player data remains local in the daemon cache. The socket defaults to
`$XDG_RUNTIME_DIR/wfcli/wfdaemon.sock`, uses mode `0600`, and can be overridden with
`WFCLI_DAEMON_SOCKET`. Processes running as the same OS user share this trust boundary.

Implementation, protocol, overlay-layout, and safety details are documented in
[developer/companion.md](developer/companion.md).
