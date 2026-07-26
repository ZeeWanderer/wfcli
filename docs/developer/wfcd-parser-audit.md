# WFCD Parser Comparison

This comparison identifies useful semantic differences; it is not a requirement to copy WFCD.
Reference snapshot:

- WFCD `warframe-worldstate-parser` at `96b681afd03c7141ed5e21b058de11149284fbb2`
- WFCD `warframe-worldstate-data` at `957f213ddcf3c1ec0e8556fc323ee8cd9a646d19`
- official PC worldstate generated at `2026-07-15T15:50:45Z`, build
  `2026.07.11.15.28/7fwjVVacxcBzO-xahK2RZg`

Ignored clones under `research/` are disposable references. No WFCD parser is a build-time or
runtime dependency.

## Open Parsing Mismatches

### Events and news

Official `Events` contains news and community posts; timed world events are in `Goals`. The
current commands expose these sections as `events` and `goals`, so their names do not match game
semantics. WFCD maps them to `news` and `events`.

A correction needs a `news` command, `events` backed by `Goals`, and a deliberate compatibility
policy for the existing names.

### Circuit choices

The parser reads obsolete `EndlessXpChoices`, while current data is in
`EndlessXpSchedule[0].CategoryChoices` under `EXC_NORMAL` and `EXC_HARD`. The existing
`endless-xp` view is therefore empty for current snapshots.

A correction needs typed normal and Steel Path Circuit tracks plus fixtures for the current
`EndlessXpSchedule` shape.

## Incomplete Views

| Current type | Meaning | Missing projection |
| --- | --- | --- |
| `season_info` | Nightwave | active challenges, reputation, challenge kind, expiry |
| `project_pct` | construction progress | Fomorian/Razorback labels and percentage formatting |
| `syndicate_mission` | syndicate mission and bounty schedule | jobs and reward pools need additional static/export data |

`archimedea` is no longer part of this list. `Conquests` is projected into Deep and Temporal
Archimedea entries with missions, factions, deviations, risks, personal modifiers, windows, and
query fields.

## Unexposed Data

- `WeeklyVaultBonusRewards`: clan weekly initiative region and reward thresholds
- calculated cycle views for Earth, Cetus, Cambion, Vallis, Zariman, and Duviri spiral; epoch
  constants need transition-boundary tests
- selected `Tmp` values such as Kinepage, sentient outpost, faceoff bonus, and charity event state

`Tmp` is an embedded JSON string and is less stable than normal worldstate fields. Add typed
projection only for a concrete command or query field with fixtures.

## Deliberate Differences

WFCD is a semantic reference, not complete ground truth. `wfcli` indexes official fields absent
from the reviewed WFCD parser, including `Descents`, `ExperimentRecommended`, and
`FeaturedGuilds`; these remain available. Combining `ActiveMissions` and `VoidStorms` for fissure
presentation is also a local choice rather than a parser-correctness requirement.

## Priority

1. Correct `Events` and `Goals` naming with fixtures for both shapes.
2. Replace `EndlessXpChoices` with current Circuit schedules.
3. Add a structured Nightwave view.
4. Add clan weekly initiative and labelled construction progress.
5. Add calculated cycles with transition-boundary tests.
