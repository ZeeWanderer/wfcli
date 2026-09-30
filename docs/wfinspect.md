# wfinspect

Read-only Warframe research using live memory, saved captures, cache resources,
and runtime events. Built with [companion](developer/workflows.md); repository
links are `wfinspectd` (development) and `wfinspect` (production).

## Start Here

```bash
wfinspect doctor
wfinspect game adapter --list
wfinspect game adapter --exe /path/to/Warframe.x64.exe
wfinspect game inventory
wfinspect game memory --help
mkdir -p ~/.local/share/bash-completion/completions
wfinspect completion bash > ~/.local/share/bash-completion/completions/wfinspect
```

Every command has `--help`. Addresses accept decimal or `0x` hexadecimal.
Use `--` before literal arguments beginning with a dash or named `help`.

`game inventory` reads current resource stacks, blueprints and foundry jobs,
including their inventory sync ID, directly from the running game.

`game adapter --exe PATH` checks metadata bindings without launching Warframe.
Metadata uses validated code signatures; fixed UI and inventory layouts remain
listed separately by `--list`.

## Memory and UI

Memory queries discover the running Warframe process by default. Add
`--capture DIRECTORY` to query saved evidence with the same reader.

```bash
wfinspect game memory maps
wfinspect game memory find 'LITH ERA' --scope readable
wfinspect game memory refs 0x123400 --length 128
wfinspect game memory path 0x123000 0x123400 --depth 24
wfinspect game memory capture research/capture --root 0x123000 --depth 6
wfinspect game memory capture research/range --range 0x123000:4096
wfinspect game memory read 0x123000 64 --capture research/range > bytes.bin
```

`--scope` selects research mappings, all readable mappings, heap, or executable
image. `--range START:LENGTH` narrows that selection and can be repeated.
Searches and walks report coverage, unreadable blocks, and exhausted limits.
Captured ranges describe available evidence, not the entire original process.
Captures are bounded, read while the game runs, and never overwrite an existing
capture directory.

```bash
wfinspect game ui movies
wfinspect game ui objects ProjectionReward
wfinspect game ui capture research/reward 'Forma Blueprint'
wfinspect game ui objects ProjectionReward --capture research/reward
wfinspect game ui relic --capture research/reward
```

`ui objects` exposes known text-object addresses, instance names and values for
a movie-path substring. Typed queries require a matching executable adapter.
`ui movies` recomputes discovery from available bytes; `ui replay` also includes
the recorded acquisition snapshot for comparison.

## Resources and Scripts

```bash
wfinspect game cache locate
wfinspect game cache packages
wfinspect game cache paths CACHE_DIR Font Conquest
wfinspect game cache extract CACHE_DIR Font /Lotus/Scripts/Libs/ConquestLib.lua research/ConquestLib
wfinspect game cache find CACHE_DIR Font 'Conquest' --split B --stream
wfinspect game cache read CACHE_DIR Font /Lotus/Scripts/Libs/ConquestLib.lua B \
  | wfinspect game script info - --adapter BUILD
```

Cache matches include resource split and byte offset. `--path` filters resource
names; `--continue-on-error` retains later results after decoding failures.
Failures remain in the report and produce a nonzero exit status.
Installation discovery reads Steam library metadata; `WFINSPECT_CACHE_DIR`
overrides the discovered cache directory.

Oodle extraction uses the bundled, pinned `unoodle` helper in `libexec/`.
Builds download its checksum-verified source and compile it alongside the other
tools; extraction needs no runtime download or Cargo installation.

```bash
wfinspect game cache decoder
```

`WFINSPECT_OODLE_LIBRARY` selects an official Linux Oodle library;
`WFINSPECT_OODLE_COMMAND` selects another helper. Explicit overrides take
precedence over the bundled decoder. Validate new game streams against an
official decoder before relying on their contents for semantic research.

Script `info` preserves raw instructions/constants and marks uncertain opcode
boundaries. `normalize`, `disassemble`, and `decompile` require complete opcode
mapping. Decompilation uses the bundled `wf-luau-decompiler` helper.

## Track Game Updates

Retain a baseline before updating the game, then take another snapshot afterward:

```bash
wfinspect game script snapshot research/scripts before --executable /path/to/Warframe.x64.exe
wfinspect game script snapshot research/scripts after --executable /path/to/Warframe.x64.exe
wfinspect game script infer research/scripts before after --output-profile candidate.json > inference.json
wfinspect game script compare research/scripts before after --profile reviewed.json > changes.json
```

Snapshots contain all `.lua` B splits, deduplicated by content hash. Names are
immutable; extraction failures are recorded and exit nonzero. Unknown bytecode
is retained for later analysis. `--package` and `--path` permit smaller captures.
Keep extracted resources in an ignored research workspace, outside Git.
Snapshot reads use the captured profile; `--profile` rechecks unchanged raw
bytes with a newer profile for the same executable.

Inference proposes mappings from unique matching bodies. It retains anchors,
ambiguities and conflicts; it does not certify native handler equivalence.
Review candidates before marking a profile `reviewed`. Comparison distinguishes
encoding changes, atom rebinding, metadata changes and changed code/constants.
Missing/undecodable dependencies and changed executable-native dependencies need
review. `--check` makes that result usable as a failing update check.
The example uses `reviewed.json` for the completed, verified candidate profile.

```bash
wfinspect game script snapshots research/scripts
wfinspect game script show research/scripts after --path Archimedea
wfinspect game script coverage research/scripts after --profile reviewed.json > coverage.json
wfinspect game script decompile --snapshot research/scripts after /Lotus/Scripts/Libs/ConquestLib.lua --profile reviewed.json
wfinspect game script features > features.json
wfinspect game script profiles BUILD > profile.json
```

`compare --features FILE` selects a feature manifest. Script dependencies include
possible literal module references, not a complete dynamic call graph. Native
behavior and external data remain explicit coverage gaps, not proven unchanged.
Profiles can supply atom names in `symbols` (decimal hash keys); raw IDs remain
in `info` and comparison. `script import` accepts `{ "profile": {...}, "scripts":
{ "/resource.lua": "bytecode-file" } }`; file paths are relative to the manifest.
`coverage` indexes opcode/atom usage and incomplete prototypes, with example
resource paths. Opcode counts stop at unknown boundaries; AUX bytes are not
guessed to be instructions.

## Runtime Evidence

```bash
wfinspect game events watch --seconds 30
wfinspect game gep state --payload-dir research/payloads
wfinspect game gep watch --seconds 60 --payload-dir research/payloads
wfinspect daemon get player
wfinspect daemon subscribe player --seconds 30
```

DBWIN has one reader per Proton prefix; additional consumers subscribe to its
feed. Slow subscribers disconnect without stalling companion. Payload files
contain private account data; inspect them before sharing.

Snapshots emit JSON, watches emit timestamped NDJSON, and raw read/normalize
commands emit bytes only. Diagnostics go to stderr. Watches are bounded by
`--seconds` and `--limit`; daemon inspection does not start or mutate the daemon.

For offline executable analysis, the [Ghidra exporter](../tools/wfinspect-ghidra/README.md)
produces reports consumed by `game report verify`, `list`, and `get`.
