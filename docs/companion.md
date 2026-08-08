# Linux/Proton Companion

`wfcompanion` observes local Warframe state, publishes player data to `wfdaemon`, and renders
Wayland overlays for relic rewards and relic selection.

## Requirements

- KDE Plasma on Wayland with KWin screenshot support and KScreen
- Tesseract 5 with English language data
- built `wfcli`, `wfdaemon`, and `wfcompanion` executables

Source-build requirements are listed in the [repository README](../README.md#build).

## Steam Launch Mode

Launch mode starts and stops the companion with Warframe and provides the process relationship
required by Linux read-only process access. Set **Warframe > Properties > General > Launch
Options** in Steam to:

```bash
/absolute/path/to/wfcli/prod/bin/wfcompanion launch -- %command%
```

Keep existing wrappers after `--`:

```bash
/absolute/path/to/wfcli/prod/bin/wfcompanion launch -- gamemoderun %command%
```

The CLI can edit the launch option after Steam is closed:

```bash
wfcli companion install --dry-run
wfcli companion install
wfcli companion uninstall
```

Use `dev/bin/wfcompanion` to test a development build. `wfcompaniond` enables the compact
diagnostic HUD; production starts with the HUD hidden.

## Standalone Mode

Run the companion as a detached user process:

```bash
wfcli companion start
wfcli companion status
wfcli companion restart
wfcli companion stop
```

Overlay controls:

```bash
wfcli companion show
wfcli companion hide
wfcli companion hud show
wfcli companion hud hide
```

`show` and `hide` control all overlays. `hud` controls only the diagnostic panel. Overlay pixels
are gated to the recognized Warframe window.

## Interaction

Press `Ctrl+Tab` while a relic overlay is visible to toggle interaction mode. KDE may request
global-shortcut permission on first use.

Interaction mode captures pointer input over the overlay. Press `Ctrl+Tab` again, click outside,
close the scene, or leave Warframe focus to return input to the game. Passive overlays remain
click-through.

## Relic Data

Warframe debug output triggers capture of the relevant game region. Reward recognition uses local
Tesseract OCR; relic selection uses era recognition. The daemon resolves items, player state,
assets, reward tables, and batched Market prices.

Reward cards show platinum, ducats, vault and ownership state, set components, and set value.
Selection cards rank owned relics using reward tables and current Market data.

## Diagnostics

```bash
wfcli companion status
wfcli companion probe
wfcli companion logs
wfcli companion paths
wfcli companion screenshot ./capture.png
wfcli companion relic-ocr ./capture.png
wfcli companion relic-ocr
```

The screenshot command captures Warframe rather than the active desktop window. Run the full
saved-image reward pipeline with:

```bash
dev/bin/wfcompanion --relic-screenshot ./capture.png
```

Incident logs use `$XDG_STATE_HOME/wfcli/wfcompanion.log`, normally
`~/.local/state/wfcli/wfcompanion.log`.

## Previews

```bash
wfcli companion preview list
wfcli companion preview image relic-rewards
wfcli companion preview video relic-suggestions
make previews
```

`make previews` renders registered scenes at 1920x1080 and 2560x1440. Matching fixtures provide
backgrounds; other outputs are transparent. Filter output with Make variables:

```bash
make previews PREVIEW_MEDIA=image
make previews PREVIEW_SCENES='relic-rewards relic-suggestions'
make previews PREVIEW_RESOLUTIONS=2560x1440
```

Direct previews can use real OCR and daemon data:

```bash
wfcompanion preview image relic-rewards --scan SCREENSHOT --background SCREENSHOT OUTPUT.png
wfcompanion preview image relic-suggestions --era all --background SCREENSHOT OUTPUT.png
```

Animated previews require FFmpeg. AlecaFrame reference previews require
[`make aleca-layout-setup`](../tools/aleca-layout/README.md).

## Player Dataset

```bash
wfcli player
wfcli player source=game
wfcli query 'dataset=player source=inventory'
```

The dataset contains game process state, collector health, and the latest account inventory and
mastery observation. It is stored in the daemon's owner-only local cache. Implementation and
protocol details are in [Companion architecture](developer/companion.md).
