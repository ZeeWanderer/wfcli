# Utility Centralization

Centralize behavior inside its owning application. Call count alone does not make code shared.

## Rules

- Keep terminal, ANSI, width, argv, and output-path helpers in `wfcli`.
- Keep fetching, persistence, query parsing/evaluation, normalization, and planner helpers in
  `wfdaemon`.
- Move code to `wfcore` only when both applications need identical stable value semantics or
  a protocol/data contract.
- Prefer a small focused module when behavior has one owner and independent tests. Do not split
  files only to reduce line count.
- Avoid compatibility wrappers after a move unless an external API contract requires one.
- Add `-spec` to exported inter-module functions and focused tests for shared behavior.

Current ownership and utility lists are in `shared_utilities.md` and `structure.md`.
