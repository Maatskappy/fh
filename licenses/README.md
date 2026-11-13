# Retained license sources

Use this inventory to locate license texts for known bundled components. Root
[NOTICE](../NOTICE) identifies components and distribution paths. These complete
texts are copied verbatim and supplement upstream notices.

| Retained text | Source |
| --- | --- |
| [Zig MIT](zig/LICENSE) | Zig 0.16.0 distribution `LICENSE` |
| [LLVM libunwind](llvm-libunwind/LICENSE.TXT) | Zig 0.16.0 `lib/libunwind/LICENSE.TXT`, including exceptions and legacy notices |
| [WASI libc](wasi-libc/LICENSE) and [MIT](wasi-libc/LICENSE-MIT), [Apache](wasi-libc/LICENSE-APACHE), [Apache + LLVM](wasi-libc/LICENSE-APACHE-LLVM) alternatives | Zig 0.16.0 `lib/libc/wasi/` files with the same names |
| [musl](wasi-libc/musl-COPYRIGHT) | Zig 0.16.0 `lib/libc/wasi/libc-top-half/musl/COPYRIGHT` (also identical to `lib/libc/musl/COPYRIGHT`) |
| [cloudlibc](wasi-libc/cloudlibc-LICENSE) | Zig 0.16.0 `lib/libc/wasi/libc-bottom-half/cloudlibc/LICENSE` |
| [Unicode V3](unicode/LICENSE) | https://www.unicode.org/license.txt, Copyright © 1991–2026 Unicode, Inc. |
| [Python](python/LICENSE) | https://raw.githubusercontent.com/python/cpython/v3.12.3/LICENSE |
| [Wasmtime](wasmtime/LICENSE) | Full official Wasmtime 48.0.8 C API archive. [pinned provenance](wasmtime/README.md) |

## Zig and WASI sources

The Zig paths above are relative to the exact [0.16.0 source tree](https://codeberg.org/ziglang/zig/src/tag/0.16.0/).
Copies came from the pinned local Zig 0.16.0 distribution.

The wasi-libc umbrella lists alternative allocators. The reviewed C fixture uses
Zig's allocator. The inventory does not imply that dlmalloc or emmalloc is linked.

## Unicode-derived data

The Unicode properties come from these sources:

- [Unicode 15.0.0 dataset](https://www.unicode.org/Public/15.0.0/ucd/ReadMe.txt).
- [CPython 3.12.3 generator](https://github.com/python/cpython/blob/v3.12.3/Tools/unicode/makeunicodedata.py).

The fh generator is `tests/native/fixtures/workspace-check/generate-printable.py`
in the source checkout. Complete pinned Python terms cover this derived data.
The module embeds no Python interpreter.

## Binary notices

The [macOS arm64 Wasmtime inventory](wasmtime/README.md#macos-arm64-binary-notices)
retains all 235 resolved dependencies, including build tools and generated-data
sources, plus Rust standard-library and compiler-runtime notices. Other targets
need their own notice review before binary publication.
