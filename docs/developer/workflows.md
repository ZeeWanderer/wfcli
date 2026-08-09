# Development Workflows

## Build

See [README build instructions](../../README.md#build) for staged
tree layout and dependencies. Contributor targets:

```bash
make dev             # debug Erlang, companion, and GUI
make prod            # optimized Erlang, companion, and GUI
make dev-erlang
make prod-erlang
make dev-companion
make prod-companion
make gui            # native Qt Widgets development client
make gui-reconfigure
make package
```

Run `make dev-erlang` before direct `wfclid` tests and after daemon application metadata changes.
Run `make prod-erlang` before direct `wfcli` tests. Run the matching companion target after Rust,
asset, or native bridge changes.

The GUI uses vcpkg manifest mode with the tracked LLVM/libc++ triplet:

```bash
export VCPKG_ROOT=/path/to/vcpkg
make gui
```

`make gui` derives `LLVM_ROOT` from Homebrew; override it to select another complete LLVM prefix.
Host tools and target libraries share one triplet. The build environment supplies LLVM's runtime
path while generated tools execute. vcpkg archives and sccache data remain under `.cache/`;
compiler output remains under `_build/`.

GUI prerequisites include CMake, Ninja, vcpkg, Autoconf, Autoconf Archive, Automake, and Libtool.
VS Code CMake Tools uses the tracked presets and existing `_build/cmake/` trees.

## Tests

- `./scripts/test-quiet eunit`: EUnit with passing output suppressed.
- `./scripts/test-quiet ct`: Common Test with passing output suppressed.
- `./scripts/test-quiet gui`: native desktop model tests with build output suppressed.
- `cargo test --locked --quiet --manifest-path apps/wfcompanion/Cargo.toml`: Rust tests.
- `make test-gui`: native desktop model tests.
- `make test`: Erlang, Rust, and native desktop suites.
- `make check`: Rust formatting, xref, tests, and both staged builds.

The quiet wrapper prints one line on success. On failure it prints a bounded tail and retains the
full log under `/tmp`. Use direct `rebar3` only while debugging a failure.

Run tests after code, fixture, build, or behavior changes. Documentation-only changes do not need
tests. Manually exercise changed CLI commands after automated tests pass.

`rebar3 ct` emits an expected `-compile(export_all)` warning for
`apps/wfcli/test/wfcli_forma_plan_SUITE.erl`.

## Generated Files

```bash
make native-compile-commands
make fix-executables
make previews PREVIEW_MEDIA=image
```

`fix-executables` applies executable mode to every tracked shebang file.
Preview variables and reference setup are documented in the
[companion guide](../companion.md#previews).

## Erlang Tools

OTP 29 is the source and runtime baseline. ELP discovers the umbrella from root `rebar.config`,
which also scans application `src/` trees recursively. Run xref after application-boundary
changes:

```bash
rebar3 xref
```

## Packaging

Treat `prod/` as an installation prefix. Packages must preserve `bin/`, `libexec/`, `BUILD_ID`,
and `BUILD_FLAVOR` together. Executables locate private files relative to that prefix. Package
adapters may relocate the complete tree but must not split those files across unrelated roots.
Declare `wfcompanion` runtime tools as package dependencies rather than copying host executables
into `libexec/`.

## Fixtures

- Worldstate and query fixtures: `apps/wfcli/test/fixtures/`
- Companion image fixtures: `apps/wfcompanion/tests/fixtures/`

Fixtures are read-only inputs. Writable caches and generated output belong under Common Test
`priv_dir` or a unique `/tmp` path.
