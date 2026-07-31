# Desktop GUI

`wfgui` is a native C++ Qt Widgets client for daemon-owned data. It starts or reuses
`wfdaemon`; closing the GUI releases its daemon activity hold.

## Build And Run

Set `VCPKG_ROOT` to a vcpkg checkout, then build:

```bash
make gui
./wfguid
```

`make gui-prod` installs the optimized client as `prod/bin/wfgui`; `make links` refreshes
the root `wfgui` link. Use `make gui-reconfigure` after changing toolchain or preset settings.

Capture a deterministic window preview with:

```bash
wfgui --screenshot /tmp/wfgui.png --size 2560x1440
```

Use `--page relic|inventory|mastery` to capture a specific view.

## Relic Planner

The Relic Planner ranks relics by expected four-player platinum value, then ducat value. `Only
owned` is enabled by default and can be disabled without another daemon request. It supports era
selection, name filtering, price refresh, vaulted state, owned counts, and Void Trace count.

Each era has independent cached state. Relic metadata appears first, prices update in the
background, and images fill in as the asset cache resolves them. Switching eras never displays
another era's data while its request is pending.

Owned relics come from the latest player inventory published by `wfcompanion`. Catalog and market
data come from `wfdaemon`.

## Inventory

Inventory joins the latest player snapshot to the managed item catalog. Categories cover parts,
relics, mods, arcanes, miscellaneous stacks, and derived sets. Search and category filtering are
local; visible card assets load progressively from the daemon cache. Newly visible assets move
ahead of queued work from cards that have scrolled away.
The grid adds columns as space permits. Hovering a set component shows its name and owned/required
count.

## Mastery Planner

Mastery Planner combines current equipment, historical mastery XP, pending builds, components,
and owned relics. It shows equipment completion and filters unfinished items by easy progress,
owned-relic availability, or tradable components. View changes filter the already loaded result.
Its grid uses the same responsive wrapping and component tooltips as Inventory. Relic Planner
reward circles show reward names on hover.
