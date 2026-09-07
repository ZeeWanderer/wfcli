# wfinspect Ghidra exporter

`ExportWfinspectReport.java` exports generic, build-keyed evidence from an existing Ghidra
project. It never embeds Warframe addresses and does not start Ghidra through `wfinspect`.

Example with a Homebrew Ghidra install:

```bash
GHIDRA_HOME="$(brew --prefix ghidra)/libexec"
"$GHIDRA_HOME/support/analyzeHeadless" PROJECT_DIR PROJECT_NAME \
  -process PROGRAM -noanalysis -readOnly \
  -scriptPath "$PWD/tools/wfinspect-ghidra" \
  -postScript ExportWfinspectReport.java REPORT.json \
  function=0x140001000 xrefs=0x140002000 'string=SyncInventoryFromDB'

wfinspect game report verify REPORT.json
wfinspect game report list REPORT.json
wfinspect game report get REPORT.json 0
```

Queries:

- `function=ADDRESS`: disassembly and decompilation of the containing function.
- `xrefs=ADDRESS`: analyzed references to an address.
- `string=TEXT`: exact UTF-8 occurrences and analyzed references.
- `scalar=VALUE`: instructions containing an exact scalar.
- `pointers=START:COUNT:WIDTH`: 4-byte image-relative or 8-byte absolute pointer table.

Reports use `wfinspect.ghidra-report` schema version 1 and contain executable SHA-256. Pass
`--adapter BUILD` to require a specific registered adapter or executable hash.
