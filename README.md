# wfcli

`wfcli` is a Warframe data toolkit for the terminal, MCP clients, and a Linux/Proton in-game
companion. A shared Erlang/OTP daemon owns network access, caches, queries, watches, Warframe
Market requests, local player observations, and Forma planning.

## Components

| Component | Role |
| --- | --- |
| [`wfcli`](docs/cli.md) | Terminal client and stdio MCP server. It parses arguments and formats data returned by the daemon. |
| [`wfdaemon`](docs/daemon.md) | Supervised OTP service for data, persistence, queries, watches, market access, player state, and planning. |
| [`wfcompanion`](docs/companion.md) | Native Linux/Proton observer and Wayland overlay. It publishes local player observations and displays contextual data such as relic prices. |
| [`wfgui`](docs/gui.md) | Native C++ desktop client for inventory, relic planning, and other account views. |
| [`wfcore`](docs/developer/shared_utilities.md) | Process-free OTP library containing shared protocols, schemas, paths, and value helpers. |

Clients start `wfdaemon` when needed. Concurrent clients reuse its parsed data and rate-limited
network work. The daemon normally stops after becoming idle; explicit start and login autostart
can keep it running.

## Requirements

CLI and daemon:

- Erlang/OTP 29
- Rebar3
- GNU Make

Companion build:

- Rust and Cargo
- Git, CMake, a C/C++ compiler, and `jq`
- MinGW-w64 for the Proton debug-output helper
- `ccache` is optional

Companion runtime:

- KDE Plasma on Wayland with KWin screenshot support and KScreen
- Tesseract 5 with English `eng.traineddata`

Desktop GUI build:

- LLVM with libc++, CMake, Ninja, and vcpkg
- Autoconf, Autoconf Archive, Automake, and Libtool
- `ccache` is optional

Homebrew provides these build tools:

```bash
brew install llvm cmake ninja autoconf autoconf-archive automake libtool
```

FFmpeg with `libvpx-vp9` is required only for animated overlay previews. `zip` is required by
`make package`.

## Build From Source

Build both development and production trees:

```bash
git submodule update --init
make build
```

Development build with debug information and host Erlang runtime:

```bash
make dev
```

Production build with optimized Rust, stripped Erlang debug information, and a self-contained
relx daemon release:

```bash
make prod
```

Generated files use these roots:

```text
_build/   Rebar3 and Cargo compiler output
.cache/   Rebar3 downloads and ccache data
dev/      staged development executables and release
prod/     staged production executables and release
```

Root links make both environments directly usable when the repository is on `PATH`:

| Development | Production |
| --- | --- |
| `wfclid` | `wfcli` |
| `wfdaemond` | `wfdaemon` |
| `wfcompaniond` | `wfcompanion` |
| `wfguid` | `wfgui` |

Useful targets:

```bash
make dev-erlang
make prod-erlang
make dev-companion
make prod-companion
make gui
make native-compile-commands
make test
make check
make previews
make fix-executables
make package
```

`make native-compile-commands` prepares clangd metadata for Blend2D, AsmJit, the native renderer
bridge, and the MinGW debug-output helper. Tracked VSCode settings use that database and the root
Cargo workspace automatically.

`make package` writes `.tar.gz` and `.zip` archives under `releases/`. Production executables
live under `prod/bin/`; private runtime files live under `prod/libexec/`.

`wfcompaniond` displays a small diagnostics HUD while Warframe is active. It reports daemon,
game-observer, debug-output, and relic-scene state. Production `wfcompanion` does not display this
HUD.

## Command-Line Client

Focused commands provide common views without requiring query syntax:

```bash
wfcli fissures
wfcli alerts --watch
wfcli baro inventory
wfcli teshin
wfcli archimedea
wfcli market 'saryn prime set'
```

Use built-in help for the complete command surface:

```bash
wfcli --help
wfcli help commands
wfcli fissures --help
wfcli completion install
```

See [Command-line client](docs/cli.md) for help forms, completion, command
semantics, and XDG path reporting.

### Queries And Watches

The query language searches worldstate, official exports, WFCD data, market metadata,
and local player observations:

```bash
wfcli query 'dataset=worldstate type=fissure hard=true'
wfcli query 'dataset=codex toxin OR heat'
wfcli query 'dataset=market lowest_sell<50'
wfcli watch 'dataset=worldstate type=alert'
```

See [Query language and watches](docs/query.md) for grammar, datasets, paging, raw source access,
and watch behavior.

### Forma Planning

```bash
wfcli forma-plan --config ./wisp.yml --visualize
wfcli visualize --plan ./wisp.plan.yml
```

Generated files default to the config directory. See
[Forma planner and visualization](docs/forma-plan.md).

### Daemon Control

Ordinary commands start the daemon automatically. Explicit controls support persistent operation,
diagnostics, updates, and login startup:

```bash
wfcli daemon status
wfcli daemon start
wfcli daemon start --idle-shutdown
wfcli daemon autostart enable
wfcli daemon update
wfcli daemon stop
```

See [Daemon lifecycle and updates](docs/daemon.md).

### Linux Companion

Steam launch mode is preferred because it starts and stops the companion with Warframe and gives
the read-only player-data collector the required process relationship. In Steam, open
**Warframe > Properties > General > Launch Options** and set:

```bash
/absolute/path/to/wfcli/prod/bin/wfcompanion launch -- %command%
```

Use `wfcli companion start` for standalone operation. Companion control and
diagnostics remain available through the CLI:

```bash
wfcli companion status
wfcli companion show
wfcli companion probe
wfcli companion paths
```

See [Linux/Proton companion](docs/companion.md) for launch options, runtime dependencies,
interaction controls, player data, and troubleshooting.

### Desktop GUI

```bash
export VCPKG_ROOT=/path/to/vcpkg
make gui
./wfguid
```

See [Desktop GUI](docs/gui.md) for current views and data requirements.

### MCP

`wfcli mcp` is a newline-delimited stdio MCP server. It starts or reuses `wfdaemon` and returns
structured data without terminal formatting:

```bash
codex mcp add wfcli -- /absolute/path/to/wfcli/prod/bin/wfcli mcp
```

See [MCP server](docs/mcp.md) for tools, resources, and cancellation behavior.

## Documentation

- [`wfcli`](docs/cli.md): help, completion, paths, [data sources](docs/data-sources.md),
  [query language](docs/query.md), and [Forma planner](docs/forma-plan.md)
- [`wfdaemon`](docs/daemon.md): lifecycle, idle policy, systemd, and updates
- [`wfcompanion`](docs/companion.md): Proton observation, OCR, overlay, and diagnostics
- [`wfgui`](docs/gui.md): native desktop client
- [`wfcli mcp`](docs/mcp.md): MCP tools and resources
- [Contributor documentation](docs/DEVELOPER.md): ownership, internals, and workflows

## License

Project code is licensed under Apache-2.0; see [LICENSE.md](LICENSE.md). That license does not grant
rights to third-party components or Digital Extremes' Warframe assets. Those assets remain under
the [Warframe Content Policy](https://www.warframe.com/en/contentpolicy). Provenance and license
notes live beside relevant files under `apps/wfcompanion/vendor/` and
`apps/wfcompanion/assets/`.
