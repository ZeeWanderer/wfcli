# Desktop GUI

`wfgui` is a native Qt Widgets client for daemon-owned data. It starts or reuses `wfdaemon` and
releases its activity lease when the window closes.

Build instructions and staged executable names are in the [repository README](../README.md#build).

Install the application launcher and notification identity:

```bash
wfcli gui install
```

Use `wfcli gui status` or `wfcli gui uninstall` to inspect or remove it.

## Pages

### Foundry

Foundry joins player inventory, pending recipes, mastery state, and catalog metadata. Search and
item-type filters run locally. Cards show ownership, mastery, favourite and vault state, component
requirements, and available quantities.

### Mastery Helper

Mastery Helper combines equipment, historical mastery XP, pending builds, components, and owned
relics. Its header shows progress within the current Mastery Rank. Filters isolate unfinished items
by available progress source. Hovering a component shows its name and owned/required count.

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

### Market

Market signs in to Warframe Market, manages regular buy and sell orders, and controls account
presence. Orders can be filtered, edited, hidden, closed, deleted, or reconciled with the current
player inventory. The open page refreshes account data once per minute.

Click a tradable item, component, relic, or relic reward on another page to open current listings.
The dialog supports exact rank, charge, star, subtype, and bulk-trade variants, copies trade
whispers, and can create an order for a signed-in account.

The password is used only for sign-in. `wfdaemon` stores the returned session token in its
owner-only state directory. Presence can follow Warframe automatically or remain online, in game,
or invisible.

## Activity Rail

The right rail shows active world cycles, Baro and Prime Resurgence windows, and grouped fissures.
Its fissure bell cycles between notifications off, active while a GUI is connected, and persistent
daemon monitoring. `wfcli notifications` controls the same setting.

## Screenshots

Render a deterministic window image without a desktop screenshot tool:

```bash
wfgui --screenshot /tmp/wfgui.png --size 2560x1440 --page foundry
wfgui --market-item 54a74454e779892d5e515621 --market-side sell \
  --screenshot /tmp/wfgui-market-item.png
```

Valid pages are `foundry`, `mastery`, `inventory`, `relic`, and `market`.
