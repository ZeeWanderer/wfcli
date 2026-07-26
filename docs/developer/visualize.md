# Visualization Pipeline

## Entry points

- CLI: `apps/wfcli/src/wfcli_visualize.erl`
- Rendering: `apps/wfcli/src/wfcli_forma_visualizer.erl`

## Where to edit what

- CLI flags/usage/errors: `apps/wfcli/src/wfcli_visualize.erl`
- HTML/SVG rendering and wx display: `apps/wfcli/src/wfcli_forma_visualizer.erl`

## Runtime notes

- HTML/SVG render paths are used even when wx is unavailable.
- wx rendering depends on display and wx libraries; see `docs/forma-plan.md` for user-facing notes.
- `wfcli visualize` accepts `--viz-config` to render the input config layout, and `--config` to override the config path when the plan YAML points elsewhere.
