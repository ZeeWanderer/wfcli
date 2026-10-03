#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "$root/_build"
fixture="$(mktemp -d "$root/_build/build-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
fail() { printf 'build: %s\n' "$*" >&2; exit 1; }

repo="$fixture/gui"
mkdir -p "$repo/scripts" "$repo/commands" "$repo/apps/wfgui"
cp "$root/Makefile" "$root/VERSION" "$repo/"
cat > "$repo/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.28)
project(build_fixture LANGUAGES CXX)
add_subdirectory(apps/wfgui)
CMAKE
cat > "$repo/apps/wfgui/CMakeLists.txt" <<'CMAKE'
add_executable(wfgui main.cpp)
CMAKE
cat > "$repo/apps/wfgui/main.cpp" <<'CPP'
#include <cstdio>
int main() { std::printf("%d", TEST_VALUE); }
CPP
cat > "$repo/CMakePresets.json" <<'JSON'
{
  "version": 6,
  "configurePresets": [{
    "name": "gui-dev", "generator": "Ninja",
    "binaryDir": "${sourceDir}/_build/cmake/gui-dev"
  }],
  "buildPresets": [{"name": "gui-dev", "configurePreset": "gui-dev", "targets": ["wfgui"]}]
}
JSON
printf '#!/bin/sh\nexit 0\n' > "$repo/scripts/stage-gui"
chmod +x "$repo/scripts/stage-gui"
ln -s "$(command -v clang++)" "$repo/commands/old-clang++"
make --no-print-directory -C "$repo" gui-dev SCCACHE= \
    CXX="$repo/commands/old-clang++" CXXFLAGS=-DTEST_VALUE=1
binary="$repo/_build/cmake/gui-dev/apps/wfgui/wfgui"
[[ "$("$binary")" == 1 ]] || fail 'initial compiler flags missing'
rm "$repo/commands/old-clang++"
ln -s "$(command -v clang++)" "$repo/commands/new-clang++"
make --no-print-directory -C "$repo" gui-dev SCCACHE= \
    CXX="$repo/commands/new-clang++" CXXFLAGS=-DTEST_VALUE=2
[[ "$("$binary")" == 2 ]] || fail 'stale compiler or flags survived'
timestamp="$(stat -c %y "$binary")"
make --no-print-directory -C "$repo" gui-dev SCCACHE= \
    CXX="$repo/commands/new-clang++" CXXFLAGS=-DTEST_VALUE=2
[[ "$(stat -c %y "$binary")" == "$timestamp" ]] || fail 'fresh configure rebuilt unchanged executable'

cat > "$repo/order.mk" <<'MAKE'
dev-erlang prod-erlang dev-companion prod-companion:
	@sleep 0.05
gui-configure-dev gui-configure-prod:
	@:
gui-dev gui-prod:
	@sleep 0.1; touch $@.done
MAKE
printf '#!/bin/sh\ntest -f gui-dev.done && test -f gui-prod.done\n' > "$repo/scripts/native-compile-commands"
chmod +x "$repo/scripts/native-compile-commands"
make --no-print-directory -C "$repo" -f Makefile -f order.mk -j8 build

repo="$fixture/native"
mkdir -p "$repo/apps/wfcompanion/src" "$repo/apps/wfcompanion/native" \
    "$repo/apps/wfcompanion/vendor/"{blend2d,asmjit} \
    "$repo/apps/wfdaemon/src/runtime" "$repo/commands"
cp "$root/apps/wfcompanion/build.rs" "$repo/apps/wfcompanion/"
printf '0.0.0\n' > "$repo/VERSION"
printf 'fn main() {}\n' > "$repo/apps/wfcompanion/src/main.rs"
touch "$repo/apps/wfcompanion/vendor/"{blend2d,asmjit}/CMakeLists.txt
printf '%s\n' '-define(ENVELOPE_VERSION, 1).' '-define(INTERFACE_PLAYER, 1).' \
    > "$repo/apps/wfdaemon/src/runtime/wfcli_local_protocol.erl"
cat > "$repo/apps/wfcompanion/Cargo.toml" <<'TOML'
[workspace]
[package]
name = "native-build-fixture"
version = "0.0.0"
edition = "2024"
TOML
cat > "$repo/commands/cmake" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$WF_TEST_CALLS"
if [[ "$1" == --build ]]; then
    [[ "$MAKEFLAGS" == *jobserver* ]]
    [[ "$*" != *--parallel* ]]
else
    [[ "$1" == --fresh && "$3" == 'Unix Makefiles' ]]
fi
SH
printf '#!/bin/sh\nexec %s "$@"\n' "$(command -v clang)" > "$repo/commands/cc"
cp "$repo/commands/cc" "$repo/commands/c++"
chmod +x "$repo/commands/"*
export WF_TEST_CALLS="$repo/cmake-calls"
native_check() {
    PATH="$repo/commands:$PATH" CC="$repo/commands/cc" CXX="$repo/commands/c++" \
        CARGO_TARGET_DIR="$repo/target" RUSTC_WRAPPER='' \
        "${CARGO:-cargo}" check --quiet --manifest-path "$repo/apps/wfcompanion/Cargo.toml"
}
native_check
[[ "$(wc -l < "$WF_TEST_CALLS")" == 2 ]] || fail 'native configure/build not called'
native_check
[[ "$(wc -l < "$WF_TEST_CALLS")" == 2 ]] || fail 'unchanged native build reran'
printf '\n' >> "$repo/commands/cc"
native_check
[[ "$(wc -l < "$WF_TEST_CALLS")" == 4 ]] || fail 'compiler replacement did not rerun native build'
CXXFLAGS=-DNEW_FLAG native_check
[[ "$(wc -l < "$WF_TEST_CALLS")" == 6 ]] || fail 'compiler flag change did not rerun native build'

repo="$fixture/cargo"
mkdir -p "$repo/scripts" "$repo/.cache/downloads" "$repo/.cache/tools/oozextract-0.5.5" "$repo/commands"
cp "$root/scripts/build-companion" "$root/scripts/build-oozextract" "$repo/scripts/"
touch "$repo/.cache/downloads/oozextract-0.5.5.crate" "$repo/.cache/tools/oozextract-0.5.5/.unpacked"
printf '#!/bin/sh\nexit 0\n' > "$repo/commands/sha256sum"
printf '#!/bin/sh\nprintf "called\\n" >> "$WF_TEST_CALLS"\nexit 42\n' > "$repo/commands/custom-cargo"
chmod +x "$repo/commands/"*
export WF_TEST_CALLS="$repo/cargo-calls"
if PATH="$repo/commands:$PATH" CARGO="$repo/commands/custom-cargo" \
    bash "$repo/scripts/build-oozextract" dev; then fail 'cargo failure swallowed'; fi
[[ "$(wc -l < "$WF_TEST_CALLS")" == 1 ]] || fail 'oozextract ignored CARGO'
printf '#!/bin/sh\nexit 0\n' > "$repo/scripts/build-oozextract"
cp "$repo/scripts/build-oozextract" "$repo/scripts/build-debug-bridge"
chmod +x "$repo/scripts/"*
if CARGO="$repo/commands/custom-cargo" bash "$repo/scripts/build-companion" dev; then
    fail 'cargo failure swallowed'
fi
[[ "$(wc -l < "$WF_TEST_CALLS")" == 2 ]] || fail 'companion ignored CARGO'

cmake "-DTEST_DIR=$fixture/toolchain" -P "$root/cmake/tests/gui-toolchain.cmake"
cmake "-DTEST_DIR=$fixture/vcpkg" -P "$root/cmake/tests/gui-vcpkg.cmake"
printf 'build system checks passed\n'
