# Desktop GUI

`wfgui` is a native Qt Widgets client for daemon-owned data. It starts or reuses `wfdaemon` and
releases its activity lease when the window closes.

Build instructions and staged executable names are in the [repository README](../README.md#build).

## Pages

### Foundry

Foundry joins player inventory, pending recipes, mastery state, and catalog metadata. Search and
item-type filters run locally. Cards show ownership, mastery, favourite and vault state, component
requirements, and available quantities.

### Mastery Helper

Mastery Helper combines equipment, historical mastery XP, pending builds, components, and owned
relics. Filters isolate unfinished items by available progress source. Hovering a component shows
its name and owned/required count.

### Inventory

Inventory covers parts, sets, relics, mods, arcanes, and miscellaneous stacks. Search, category,
ownership, and sorting controls are local. Visible assets are prioritized over cards outside the
viewport.

### Relic Planner

Relic Planner ranks relics by expected four-player platinum value, then ducat value. It supports
era and name filters, owned-only display, price refresh, vault state, owned counts, and Void Trace
count. Hovering a reward shows its name.

Each era keeps independent state. Metadata appears first; prices and images update in place.
Changing era never displays another era's results while data is pending.

## Activity Rail

The right rail shows active world cycles, Baro and Prime Resurgence windows, and grouped fissures.
Its fissure bell cycles between notifications off, active while a GUI is connected, and persistent
daemon monitoring. `wfcli notifications` controls the same setting.

## Screenshots

Render a deterministic window image without a desktop screenshot tool:

```bash
wfgui --screenshot /tmp/wfgui.png --size 2560x1440 --page foundry
```

Valid pages are `foundry`, `mastery`, `inventory`, and `relic`.
