# Forma Planner

`forma-plan` finds a shared slot-polarity layout that satisfies several builds with
minimum Forma cost. `visualize` renders a saved plan or input configuration.

## Run

```bash
wfcli forma-plan --config docs/forma_plan.example.yml
wfcli forma-plan --config wisp.yml --visualize
wfcli visualize --plan wisp.plan.yml
```

Important options:

- `--config FILE`: load YAML build definitions; repeatable.
- `--allow-omni`: permit Omni Forma.
- `--allow-umbral-forma`: permit Umbral Forma.
- `--prefer-omni`: prefer flexible Omni assignments where possible.
- `--max-forma N`: cap total Forma expenditure.
- `--show-alt`: include near-optimal alternatives.
- `--output FILE`: write plan YAML.
- `--visualize`: render after planning.
- `--viz html|image|wx`: choose the renderer.
- `--viz-output FILE`: choose visualization output.
- `--viz-config`: also render the input layout.

When output paths are omitted, generated files are placed beside the provided config.

## Config

Use [forma_plan.example.yml](forma_plan.example.yml) as the complete starting example.

Configs describe:

- item type, capacity, Reactor/Catalyst state, and existing slot polarities;
- aura, stance, and Exilus slots;
- named builds containing mods and optional arcanes;
- optional fixed mod-to-slot assignments;
- Omni, Umbral, preference, and total-Forma constraints.

Mod polarity and cost may be omitted when cached `ExportUpgrades_en.json` metadata can
resolve them. Polarity symbols are `V`, `D`, `-`, `=`, `Y`, `U`, `O`, and `P`; `null`
means an unpolarized slot.

Capacity rules:

- Warframes use base 30 and Reactor-doubled 60.
- Weapons, companions, and melee use base 30 and Catalyst-doubled 60.
- Necramech capacity is supplied by the config.
- Matching aura/stance polarity doubles contribution; mismatch halves it, rounded.

## Output

The plan records target slot polarities, Omni assignments, total Forma, each build's
slot-to-mod assignment, and configured arcanes. Unsatisfied constraints are returned as
validation errors.

HTML/SVG rendering works without wx. The wx renderer requires Erlang wx, GTK, a working
display session, and the normal desktop theme packages.
