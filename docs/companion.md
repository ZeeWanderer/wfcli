# Linux/Proton Companion

`wfcompanion` observes local Warframe state, publishes player data to
`wfdaemon`, and renders Wayland overlays.

Current overlays:

- relic rewards with Market prices, ducats, vault and ownership state, set
  components, and set value;
- relic recommendations ranked from owned relics, reward tables, and Market
  prices.

## Requirements

Runtime:

- KDE Plasma on Wayland
- KScreen and Spectacle
- Tesseract 5 with English language data
- a built `wfcli` and `wfdaemon`

Build:

```bash
git submodule update --init
make companion
```

Binaries are staged at `dev/bin/wfcompanion` and
`prod/bin/wfcompanion`. `wfcompaniond` points to the development build and
enables its diagnostic HUD.

## Steam Launch Mode

Launch mode is preferred. It starts companion with Warframe, stops it when the
game exits, and gives the read-only player collector the process relationship
required by Linux ptrace policy.

Set Warframe's Steam launch options:

```bash
/absolute/path/to/wfcli/prod/bin/wfcompanion launch -- %command%
```

Use `dev/bin/wfcompanion` when testing a development build. Keep existing
wrappers after `--`:

```bash
/absolute/path/to/wfcli/prod/bin/wfcompanion launch -- gamemoderun %command%
```

Check it from another terminal:

```bash
wfcli companion status
```

## Standalone Mode

Standalone mode runs companion as a detached user service:

```bash
wfcli companion start
wfcli companion status
wfcli companion restart
wfcli companion stop
```

Visibility:

```bash
wfcli companion show
wfcli companion hide
wfcli companion hud show
wfcli companion hud hide
```

`show` and `hide` control the full overlay. `hud` controls only the diagnostic
panel. Overlay pixels appear only over the recognized Warframe window.

## Interaction

Press `Ctrl+Tab` while a relic overlay is visible to toggle interaction mode.
KDE may request global-shortcut permission on first use.

Interaction mode captures pointer input over the overlay. Another
`Ctrl+Tab`, an outside click, scene closure, or Warframe focus loss returns
input to the game. Passive overlays remain click-through.

## Data Flow

Companion receives Warframe debug output through a small Wine DBWIN helper and
uses `EE.log` as a delayed fallback.

Relic rewards trigger one window capture. Companion detects the one-to-four
card layout and runs local Tesseract OCR over reward names. The daemon resolves
items, player metadata, assets, and one batched set of Market quotes.

Relic selection captures only the era selector. The daemon ranks relics from
cached player inventory, WFCD reward tables, and Market quotes.

## Diagnostics

```bash
wfcli companion probe
wfcli companion logs
wfcli companion screenshot ./capture.png
wfcli companion screenshot --target screen ./screen.png
wfcli companion relic-ocr ./capture.png
wfcli companion relic-ocr --target screen
```

Run the full saved-image reward pipeline:

```bash
dev/bin/wfcompanion --relic-screenshot ./capture.png
```

Incident log:

```text
$XDG_STATE_HOME/wfcli/wfcompanion.log
```

Default fallback is `~/.local/state/wfcli/wfcompanion.log`. Automatic captures
use `$XDG_CACHE_HOME/wfcli/captures` or `~/.cache/wfcli/captures` and are
removed after decoding.

## Previews

```bash
wfcli companion preview --list
wfcli companion preview relic-rewards
wfcli companion preview --all
make previews
```

`make previews` defaults to 2560x1440. Set `PREVIEW_SIZE=WIDTHxHEIGHT` to
change it. Animated previews require FFmpeg:

```bash
wfcli companion preview --animate relic-loading
make preview-videos
```

## Player Dataset

```bash
wfcli player
wfcli player source=game
wfcli query 'dataset=player data.phase=game'
wfcli query 'dataset=player source=inventory'
```

Sources:

- `game`: process, Proton paths, and stopped/launcher/game phase;
- `collector`: DBWIN and fallback-log counters;
- `inventory`: account payload plus typed inventory and mastery indexes.

Player data stays in the daemon's owner-only local cache. See
[Companion architecture](developer/companion.md) for implementation and
protocol details.
