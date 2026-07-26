# AlecaFrame Overlay Feature Catalog

Research snapshot: AlecaFrame 2.6.90, released June 30, 2026. The current
official documentation and the matching packaged client under ignored
`research/alecaframe/2.6.90/` were inspected in July 2026.

This document distinguishes contextual in-game overlays from AlecaFrame's normal desktop
application. It is an implementation reference, not a commitment to reproduce every feature.

Evidence labels used below:

- **Official**: described by current AlecaFrame documentation.
- **Package**: present in the 2.6.90 manifest, HTML, JavaScript, or decompiled C# client.

Local implementation status:

| Surface | `wfcompanion` status |
| --- | --- |
| Relic reward selection | Automatic trigger, local OCR, daemon item resolution, lowest online sell quote, and passive overlay |
| Relic recommendation | Research reference |
| Chat Riven analysis | Research reference |
| Riven reroll comparison | Research reference |
| Trade-completion prompt | Research reference; requires authenticated Market workflows |
| TennoFinder notification | Research reference; generic notification preview only |

## In-Game Catalog

AlecaFrame officially documents four overlay features. Its package implements them with
three contextual windows, plus two additional in-game notification windows.

### Relic reward selection

**Official, Package.** Opens automatically when a fissure presents reward choices.

Displayed for each detected reward:

- item name and platinum value, with the highest-value reward highlighted;
- ducat value;
- vaulted and favourite markers;
- whether the parent weapon or Warframe is crafted or mastered;
- owned component count versus recipe requirement;
- other components in the set, their owned counts, and full-set platinum value.

The footer can show current account platinum and ducats. An optional setting copies all
recognized rewards and prices to the clipboard. The window closes after the reward-selection
interval.

The packaged default window uses a 1000-pixel reward area plus a 420-pixel side column and
60-pixel footer allowance at 1080-pixel game height. It is `(445, 630, 1420, 355)` at 1920x1080.
Its `main` margin, border, `.relicHolder` padding, 16% footer, and 400-pixel sidebar put cards at
`(469, 654, 972, 256)`. Each card uses four stable rows: name; platinum/vaulted/favourite/ducats;
crafted and owned/required state; then other set components and set platinum value. `wfcompanion`
renders the full shell and leaves unavailable card, footer, and sidebar fields blank.

Detection is not supplied by a semantic Overwolf event. `OCRHelper` receives Warframe's live
`OutputDebugString` stream through the Windows DBWIN mapping/events and passes each message to
`EELogProcessor`. `Got rewards` waits about 650 ms, captures Warframe, crops reward labels, sends
them to AlecaFrame's OCR service, fuzzy-matches item names, and requests item and set prices in
one batch. Requiem relics are deliberately skipped in this version.

### Relic recommendation

**Official, Package.** Opens when the void-fissure relic chooser appears. It displays up to
32 owned relics for the detected era, ordered and filtered like the desktop Relic Planner.

The compact cards show:

- relic name, count owned, vaulted state, and favourite state;
- expected platinum and expected ducats for opening the relic;
- current void traces and planner refresh progress.

Desktop planner filters can be exported to this overlay. Useful orderings include expected
platinum, expected ducats, missing mastery items, and value gained by refinement. AlecaFrame
warns that owned counts may become stale during endless missions because its inventory feed
updates during loading screens.

`EELogProcessor` uses `ThemedProjectionManager.lua: LoadingCompleteEnd` as the trigger. A small
screenshot crop is OCRed to determine Lith, Meso, Neo, Axi, Requiem, or All. The recommendation
itself comes from AlecaFrame's cached player inventory and relic planner, not from OCRing every
visible relic tile.

### Chat Riven analysis

**Official, Package.** Opens automatically after the user follows a Riven link in game chat.
The shared Riven overlay displays:

- weapon and Riven names;
- positive and negative stats, per-stat roll quality, and overall grade;
- similar Rivens, similarity percentage, price, source, and links;
- which attributes match known good rolls and acceptable negative attributes.

`EE.log` identifies the detailed-purchase dialog and randomized-mod item. AlecaFrame then
captures and OCRs the Riven card. The overlay is passive until Overwolf's interaction hotkey is
pressed.

### Riven reroll comparison

**Official, Package.** Opens when a Riven is selected for cycling. The left panel retains the
old Riven; after a reroll the right panel shows the new Riven. Both use the same stats, grades,
similar listings, prices, and good-roll analysis as chat Riven mode.

`EE.log` supplies selection, confirmation, completion, and close signals. Screenshots before
and after cycling are OCRed. This is a second mode of the same packaged `RivenOverlay` window,
not a separate renderer.

### Trade-completion prompt

**Package only.** When AlecaFrame recognizes a completed in-game trade and can match it to the
connected Warframe Market account, an interactive prompt identifies the other player and item.
It closes or decrements the matching regular order, or closes the matching Riven auction. The
user can also submit positive reputation. If untouched, this version automatically performs
the close action after a short countdown.

This depends on account authentication, current Market orders, and parsing the trade-confirmation
text from `EE.log`. It is not part of the official four-overlay overview.

### TennoFinder notification

**Package only.** A generic six-second notification window is used by AlecaFrame's separate
TennoFinder squad tool for joins, leaves, kicks, disbands, and squad messages. It can play a
sound. Source places it against the right edge with its bottom near 80% of game height, not at the
top and not inside the relic window. This is not a Warframe data overlay and should not be
reproduced as a product-specific feature. A generic notification scene may still be useful for
daemon watches.

### Not in-game overlays

These are normal desktop or external notification features and must not be counted as overlay
surfaces:

- Foundry, Inventory, Mastery Helper, Relic Planner, Riven Explorer, Stats, Trading Analytics,
  Warframe Market account management, build tools, and squad management;
- Windows toast and Discord webhook notifications for world cycles, fissures, conversations,
  Market messages, and Riven sniper matches;
- the main AlecaFrame window and separate desktop-only build and TennoFinder windows.

## Warframe Market Account Features

AlecaFrame 2.6.90 can authenticate a Warframe Market account and:

- show regular orders and Riven auctions/contracts;
- create buy or sell orders from inventory and set views;
- list Rivens, edit price and quantity, change visibility, remove orders, and repair quantities
  that no longer match inventory;
- copy a ready-to-paste `/w <player> ...` buy or sell message after selecting a Market order;
- receive account messages and status through a Market socket;
- match completed game trades to orders, close or decrement them, and optionally leave
  reputation through the trade-completion prompt.

Price lookup does not require account integration. `wfdaemon` uses the public Market catalog,
rate limiter, coalescing, and quote cache for relic prices. Authenticated account integration is
separate: it requires owner-only credential storage, explicit user actions, and an API/rules
review. Overlay code must never own Market credentials.

## Project Ownership

Keep current boundaries:

- `wfcompanion` owns DBWIN event detection, fallback `EE.log` tailing, event-triggered capture, crop
  profiles, OCR, confidence, transient overlay scenes, visibility, and interaction state.
- `wfdaemon` owns canonical item/relic identities, drop semantics, player snapshots, Market
  access/cache, and reusable relic-value calculations.
- `wfcli` owns terminal commands and formatting. It may inspect diagnostics and toggle the
  overlay, but it does not orchestrate visual scenes.

Screenshots and image crops stay inside `wfcompanion`. Only normalized labels, canonical IDs,
confidence, and resulting player events may cross the local socket. Account inventory belongs
in the daemon's `player` dataset; display timing and placement do not.

Native responsibilities already have explicit module boundaries:

- `observer` and `debug_output`: game process, Proton, DBWIN, and fallback log events;
- `capture`: event-triggered active-window capture;
- `relic`: crop selection, OCR cleanup, daemon resolution, and quote orchestration;
- `daemon`: typed request IDs, reconnect, replay, and player publication;
- `overlay`, `ui_layout`, and `painter`: scene state, Taffy layout, and Blend2D rendering;
- `preview`: deterministic still and animated scene rendering.

## Local Implementation

### Relic reward overlay

Current pipeline:

1. Deduplicate `Got rewards` debug events.
2. Delay capture for game UI stabilization and retry once after recognition failure.
3. Detect one to four reward cards from their bottom-border geometry.
4. OCR only reward-name crops with local Tesseract.
5. Clean OCR artifacts and batch candidate resolution through the daemon Market manifest.
6. Batch resolved item quotes through the daemon-wide rate-limited Market queue.
7. Render recognized names, lowest online sell prices, and highest-price highlighting in one
   final card update.
8. Hide on deadline, focus loss, or explicit companion hide.

`lowest sell` is the lowest sampled online sell order, not a fixed item value. Missing or stale
quotes retain their explicit state rather than being presented as authoritative prices.

### Relic recommendation design

Visible-tile annotation can use OCR plus daemon-owned relic drops and quotes. Full recommendation
also needs player inventory, void traces, favourites, mastery state, and refinement assumptions.
Expected-value calculation belongs in `wfdaemon` so CLI, query, and native interfaces can reuse
one typed result with quote timestamps and assumptions.

### Riven analysis design

Riven overlays can reuse capture and OCR infrastructure but require a separate parser and domain
model for stat grades, disposition, comparable listings, and old/new reroll state.

### Authenticated Market workflows

Login, order mutation, copied whisper actions, and trade completion require an authenticated
daemon capability and a confirmation-oriented desktop interface. Unattended order mutation is
outside the passive overlay boundary.

## Capture And Safety Constraints

- Process-memory reads are limited to the reviewed read-only inventory collector. No Wine DLL
  injection, Vulkan layers, render hooks, packet interception, synthetic input, or game-file
  modification.
- Capture only the user-authorized Warframe window. Do not continuously capture the desktop.
- Trigger capture from typed game events; do not run OCR every frame.
- Keep passive scenes click-through. Interactive mode needs an explicit global-shortcut and
  pointer-region transition.
- Do not persist captures by default. An opt-in diagnostic mode may retain bounded owner-only
  crops with an expiry.
- Never upload screenshots or player data by default.

## Verification Gates

- Replay fixture log lines to prove each trigger, deduplication rule, and close condition.
- Test saved reward crops across supported resolutions, UI scales, themes, one-to-four-player layouts,
  and loading/error states.
- Reject or visibly mark low-confidence OCR; never silently substitute the nearest item.
- Verify one reward screen produces one daemon batch and no direct Market HTTP from companion.
- Test fresh, cached, stale, partial, rate-limited, and unavailable quote responses.
- Pixel-test every scene and live-test Warframe focus gating against another fullscreen game.
- Measure capture-to-overlay latency and CPU use; no capture or repaint loop may run while idle.

## Evidence Map

Local 2.6.90 package:

- `package/manifest.json`: five `in_game_only` windows and desktop-only exclusions.
- `package/web/relicOverlay.html` and `assets/js/relicOverlay/main.js`: reward fields, highlight,
  clipboard option, placement, and lifetime.
- `package/web/relicRecommendation.html`: compact recommendation fields.
- `package/web/rivenOverlay.html`: Riven stats, grades, similar prices, good rolls, and comparison.
- `package/web/tradeFinishedNotification.html`: order close and reputation prompt.
- `package/web/InGameNotification.html`: generic notification window.
- `csharp/.../Utils/EELogProcessor.cs`: relic, recommendation, Riven, and trade triggers.
- `csharp/.../Utils/OverlaysHandler.cs`: relic-era OCR and recommendation startup.
- `csharp/.../OCRHelper.cs`: reward capture, OCR, enrichment, and non-overlay notifications.
- `csharp/.../Data/RivenOverlays.cs`: chat and reroll OCR modes.
- `csharp/.../Data/WFMarketHelper.cs`: completed-trade matching.
- `package/web/assets/js/main/mainInventory.js`: copied Market whisper construction.

Current public references:

- [AlecaFrame overlay overview](https://docs.alecaframe.com/overlays/overview)
- [Relic rewards](https://docs.alecaframe.com/overlays/relic-rewards)
- [Relic recommendation](https://docs.alecaframe.com/overlays/relic-recommendation)
- [Chat Riven](https://docs.alecaframe.com/overlays/riven-chat)
- [Riven reroll](https://docs.alecaframe.com/overlays/riven-reroll)
- [Warframe Market feature](https://docs.alecaframe.com/features/wfm)
- [Current Overwolf package version](https://www.overwolf.com/app/alejandro_cabrerizo-alecaframe)
