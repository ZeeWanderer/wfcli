# Vendored Native Sources

Blend2D and AsmJit are pinned Git submodules:

- `blend2d/`: Blend2D 0.21.2 commit
  `def0d1238c3e5d0983bb848e5676049d829e435b`
- `asmjit/`: AsmJit 1.21.0 commit
  `b56f4176cb9b0c0501da659ac54d4c5877862c7b`

The source trees match the Blend2D 0.21.2 release archive. CMake receives the
AsmJit checkout through `ASMJIT_DIR` and embeds it into static Blend2D.
Both projects use the Zlib license; see each submodule's `LICENSE.md`.

The published `blend2d` Rust crate is not used. Its latest release wraps a
2019 Blend2D snapshot and does not expose external image buffers safely.
