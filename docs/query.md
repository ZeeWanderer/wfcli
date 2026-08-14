# Query Language and Watches

Focused commands such as `mods`, `items`, `codex`, `enemies`, and `drops` accept plain
search text. The `query` command uses the same language across several datasets. Use it
when you need field filters, boolean logic, sorting, or results from more than one source.

## Unified Query

```bash
wfcli query [options] <query...>
```

By default, `query` searches every public dataset: `worldstate`, `mods`,
`items`, `codex`, `enemies`, and `drops`. Select one or more inside the query;
`all` also includes local companion-provided player data, Warframe Market
metadata, and daemon diagnostics:

```bash
wfcli query 'dataset=worldstate fissure'
wfcli query 'dataset=codex|drops serration'
wfcli query 'dataset=player source=game data.phase=game'
wfcli query 'dataset=market tag=prime lowest_sell<50'
wfcli query 'dataset=diagnostics kind=asset'
```

The daemon manages and periodically refreshes `enemies` and `drops` data.
`wfcli update --wfcd` requests an immediate refresh. `player` is local-only and
is empty until a companion or another owner-only local client publishes observations.
`market` loads the public item manifest and attaches quotes already present in daemon cache.
Unified query never expands a broad catalog match into thousands of price requests. Use
`wfcli market QUERY` for bounded live quotes.
`diagnostics` contains current friendly-name and asset-resolution failures. Use
`wfcli diagnostics unresolved` for its focused table.

Useful options:

- `--limit N` and `--offset N` page each dataset. Without `--limit`, all matches are returned.
- `--output-format table|block` selects rendering.
- `--raw` preserves identifiers and UTC timestamps.
- `--refresh`, `--ttl`, `--cache`, and `--lang` control worldstate fetching.
- `--exports-dir` and `--knowledge-dir` override catalog locations.

## Expressions

```text
expression := or-expression
or         := and-expression (OR and-expression)*
and        := unary ((AND)? unary)*
unary      := NOT unary | primary
primary    := clause | "(" expression ")"
clause     := term | key operator value ("|" value)*
operator   := = | != | ~ | >= | <= | > | < | :
```

- Adjacent expressions are implicitly ANDed.
- Boolean operators are uppercase `NOT`, `AND`, and `OR`.
- Precedence is `NOT`, then `AND`, then `OR`; parentheses override it.
- A double-quoted value is one substring phrase.
- Backslash escapes the next syntax character.
- `key:value` uses that field's default comparison, normally substring matching.
- `value1|value2` means either value inside one field filter.
- Use `OR` between complete expressions.
- `sort=field` sorts ascending; `sort=-field` sorts descending.

Shell quoting matters. Use outer single quotes when the query contains double quotes:

```bash
wfcli codex '"critical chance" OR category=Warframes'
```

## Examples

```bash
wfcli query 'type=Fissure void'
wfcli query 'type=Fissure|Alert data.MissionType=MT_DEFENSE'
wfcli query '(fissure OR alert) NOT expired'
wfcli query 'type=Alert sort=expiry'
wfcli items '(braton OR burston) masteryReq>=8'
wfcli mods 'baseDrain>=4 type=MELEE|PRIMARY'
wfcli codex '"critical chance" OR category=Warframes'
wfcli drops 'enemy~corrupted rarity=Rare'
```

Worldstate fields include `name`, `id`, `type`, projected column names, and raw
`data.<path>` fields relative to each normalized record. Parsers add semantic fields; they
do not own or hide source data. Query the immutable full source tree through the query-only
`raw_worldstate` entity when no normalized record exists or an absolute path is needed:

```bash
wfcli query 'dataset=worldstate type=raw_worldstate data.Conquests.0.Type=CT_LAB extract=data.Conquests.0.Missions.*.missionType'
```

Player projections retain their source object under `data.*`; normalized nested fields use
`typed.*`. Raw and typed representations share one or more origins. Player queries prefer typed
records for covered origins while retaining raw records with no projection:

```bash
wfcli query 'dataset=player type=player_upgrade rank>=8'
wfcli query 'dataset=player typed.configs.0.upgrade_slots.0.rank=8'
wfcli query 'dataset=player view=raw origin=inventory.raw.Suits.0'
wfcli query 'dataset=player view=both origin=inventory.raw.Suits.0'
```

`view=auto|raw|typed|both` is a player-only top-level control. `auto` is the default.

Catalog fields differ by dataset; invalid fields and operators are reported as query errors.
Run `wfcli COMMAND --help` for focused field flags and examples.

## Focused Commands

Focused commands are convenience views over the same parser and query engine:

- `mods`: mod type, polarity, rarity, compatibility, drain, and text.
- `items`: official export names and fields, optionally restricted by export file.
- `codex`: official PublicExport Codex-like records and categories.
- `enemies`: WFCD enemy stats, faction, descriptions, and resistances.
- `drops`: WFCD drops searchable from either the item or enemy direction.
- `player`: local source namespaces published through the daemon companion socket.
- `market`: public item metadata plus daemon-cached top-order quotes. `wfcli market` adds
  bounded live quote fetching and price-specific formatting.
- `diagnostics`: current daemon metadata-resolution failures.

They add useful defaults and dataset-specific formatting; they do not implement a
separate query language.

## Watches

`watch` keeps one or more worldstate queries subscribed to the daemon:

```bash
wfcli watch --spec alerts
wfcli watch --spec 'fissures:tier=lith' --spec 'alerts:reward~endo'
wfcli alerts --watch --always
```

A spec is `<command>` or `<command>:<query>`. Repeat `--spec`, or place specs after
`--`. Multiple command names inside one spec may be separated with `|`.

Watch controls:

- `--interval SECONDS` sets the polling interval, with a 60-second minimum.
- `--once` prints one update and exits.
- `--always` prints unchanged ticks too.
- `--diff-style inline|list|diff|none` controls change rendering.
- `--diff` is shorthand for `--diff-style list`.
- `extract=data.<path>` prints a selected raw worldstate field.

The daemon fetches and parses one worldstate snapshot per cycle, then evaluates all due
subscriptions against it.

Developer implementation notes live in
[developer/query-language.md](developer/query-language.md).
