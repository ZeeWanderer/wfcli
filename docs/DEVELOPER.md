# Contributor Documentation

User-facing setup and usage start in `README.md` and the top-level guides under `docs/`.
Documents in `docs/developer/` describe implementation ownership, protocols, data pipelines,
tests, and upstream research.

## Architecture

- `structure.md`: OTP applications, native companion, and ownership boundaries
- `daemon.md`: lifecycle, supervision, queues, protocol compatibility, and hot updates
- `entities.md`: normalized searchable entities and the daemon/CLI rendering boundary
- `shared_utilities.md`: stable cross-application helpers and schemas
- `centralization.md`: criteria for moving or splitting code
- `cli.md`: command dispatch, option parsing, and terminal output
- `companion.md`: native observer, local protocol, player data, market requests, and overlay
- `player-data.md`: AlecaFrame inventory source, payload semantics, and collector boundary
- `assets.md`: embedded and dynamic texture ownership, caching, and renderer boundaries

## Data And Queries

- `worldstate.md`: fetching, indexing, translation, raw-source access, and watches
- `exports.md`: official PublicExport files and catalog loading
- `knowledge.md`: official Codex and optional WFCD catalog ownership
- `query-language.md`: grammar, AST compilation, field schemas, and evaluator design
- `table_layout.md`: terminal table layout rules
- `forma_plan.md`: planner queue, model, search, and tests
- `visualize.md`: Forma visualization entry points

## Development

- `workflows.md`: build, test, fixture, and metadata routines
- `adding_features.md`: checklist for new commands and data sources
- `tools.md`: local inspection and benchmark helpers

## Research And Audits

- `wfcd-parser-audit.md`: known differences from reviewed WFCD parsers
- `alecaframe-overlay-catalog.md`: upstream overlay feature catalog and local implementation status
- `overwolf-alecaframe-overlay-research.md`: acquisition mechanisms, Wayland design, safety
  boundary, and source evidence

MCP adapter behavior is documented in the user and integration guide at `docs/mcp.md`.
