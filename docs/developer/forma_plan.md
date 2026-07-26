# Forma-Plan Pipeline

## Entry points

- CLI: `apps/wfcli/src/wfcli_forma_plan.erl`
- Daemon queue: `apps/wfdaemon/src/wfcli_forma_service.erl`
- Core solver: `apps/wfdaemon/src/wfcli_forma_planner.erl`
- Models and validation: `apps/wfdaemon/src/wfcli_forma_model.erl`
- Mod lookup (defaults): `apps/wfdaemon/src/wfcli_forma_mod_db.erl`
- YAML config loader: `apps/wfdaemon/src/wfcli_forma_config.erl`
- Visualization helpers: `apps/wfcli/src/wfcli_forma_visualizer.erl`

## Where to edit what

- CLI flags/usage/errors: `apps/wfcli/src/wfcli_forma_plan.erl`
- Queueing and data-only replies: `apps/wfdaemon/src/wfcli_forma_service.erl`
- Plan search strategy or constraints: `apps/wfdaemon/src/wfcli_forma_planner.erl`
- Item/build schema normalization: `apps/wfdaemon/src/wfcli_forma_model.erl`
- YAML parsing and error shape: `apps/wfdaemon/src/wfcli_forma_config.erl`
- Mod lookup source: `apps/wfdaemon/src/wfcli_forma_mod_db.erl`
- YAML, HTML, and SVG output: the CLI modules above.

## Concurrency and search

The daemon serializes plan requests because one solver run can use every online scheduler.
The solver first finds a serial incumbent, splits the remaining frontier into bounded weighted
tasks, runs at most one worker per scheduler, and merges results deterministically. Search
budgets are split by estimated task weight.

Budget exhaustion is not itself failure when an incumbent exists. The solver attempts a
second bounded search below the incumbent cost; absence of a cheaper plan certifies the result.
Without certification it still returns the best valid plan and logs a warning. It returns
`search_budget_exhausted` only when no valid incumbent exists.

## Tests and fixtures

- Forma plan tests live in `apps/wfcli/test` (see `wfcli_forma_plan_SUITE.erl`).
- Test configs, including `wisp.yml`, live in `apps/wfcli/test/fixtures/`.
- Sample config lives under `docs/forma_plan.example.yml`.
