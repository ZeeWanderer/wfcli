# Development Workflows

## Build

See [README build instructions](../../README.md#build-from-source) for staged
tree layout and dependencies. Contributor targets:

```bash
make dev             # debug Erlang, relx dev release, debug companion
make prod            # stripped Erlang, bundled ERTS, release companion
make dev-erlang
make prod-erlang
make dev-companion
make prod-companion
make package
```

Run `make dev-erlang` before direct `wfclid` tests and after daemon application metadata changes.
Run `make prod-erlang` before direct `wfcli` tests. Run the matching companion target after Rust,
asset, or native bridge changes.

## Tests

- `./scripts/test-quiet eunit`: EUnit with passing output suppressed.
- `./scripts/test-quiet ct`: Common Test with passing output suppressed.
- `cargo test --locked --quiet --manifest-path apps/wfcompanion/Cargo.toml`: Rust tests.
- `make test`: Erlang and Rust suites.
- `make check`: Rust formatting, tests, and both staged builds.

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

OTP 29 is the source and runtime baseline. ELP discovers the umbrella from root `rebar.config`.
ELP 0.50.0 can crash its Erlang lint service on OTP 29 functions carrying
`{unsafe,possibly}` metadata, including `socket:open/3` and `binary_to_term/2`; this is an ELP bug,
not a parser error in the affected module. EqWAlizer is not a project gate.

Run xref after application-boundary changes:

```bash
rebar3 xref
```

Native records and `compr_assign` remain experimental in OTP 29 and are not enabled.

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
