# Wasmtime native dependency

fh statically links the full official Wasmtime LTS 48.0.8 C API. It uses
Apache-2.0 WITH LLVM-exception. The complete upstream [LICENSE](LICENSE) is
retained here and installed in release bundles.

No platform library binaries are committed. The smaller `min/` library lacks a
portable Wasm compiler, so fh does not use it.

## Pinned archives

Use these identities to verify the dependency:

| Identity | Value |
| --- | --- |
| Upstream release | https://github.com/bytecodealliance/wasmtime/releases/tag/v48.0.8 |
| Source commit | `7b6c29ec3e9a49c97da231665cbd8eead9ccbda0` |
| Archive URL pattern | `https://github.com/bytecodealliance/wasmtime/releases/download/v48.0.8/wasmtime-v48.0.8-<target>-c-api.tar.xz` |

`build.zig.zon` pins the immutable Zig hashes below. The build lazily fetches only
the selected target. Each archive supplies matching `include/`, `lib/libwasmtime.a`
and `LICENSE`. Keep headers and library from the same archive.

| Release target | Zig package hash | Archive SHA-256 | Archive bytes |
| --- | --- | --- | --- |
| x86_64-macos | `N-V-__8AAOqemASKGgvxRMtawxc1wyNJszfs2iJwIsxHaMjR` | `07dc84f84debc1cca9f79c5b75200799296bb53d83f2e9d0e8dc83fe05245a63` | 14782760 |
| aarch64-linux | `N-V-__8AADrnsQVlbwtW_ahWSdySM1xTz-YoBJeKntzvY7PC` | `3bb7d77fcbf0da214b7d56fc1f244e77b6dbb51b740c63ff7cbd8ece398308dc` | 13602736 |
| x86_64-linux | `N-V-__8AAOJJZwb2tvkkL3kZBs2RHoUeMuTnq5w6NT_wnhBX` | `6cd2e5a976d68932afb546c2d14d89ba9e5578127a9716a13500dde40fc1e0e6` | 15895620 |
| aarch64-macos | `N-V-__8AAMbdPQTKr09Kbm-5hPVE6e2CPpY9vslxOAPN1aIv` | `2c7c4e75ca41f505867ef7c836c942c6b1190f708939753d10d1927585eaed59` | 12899256 |

## Linking and runtime requirements

The build links the static archive as an object with these dependencies:

| Dependency | Use |
| --- | --- |
| libc | All targets. |
| pthread, dl, m | Linux system libraries. |
| `unwind` | Explicitly linked Zig unwinder. Ordinary C compiler drivers supply one implicitly. Zig needs it explicitly when cross-linking the Rust archive. |

Consumers need only fh and package files. They need no Rust, Cargo, Wasmtime CLI
or dynamic Wasmtime library. `zig-pkg/` is ignored. Compiling the native engine is
a developer alternative, rather than a default build step.

## Rebuild from source

Obtain the exact commit above. Follow its [C API build instructions](https://github.com/bytecodealliance/wasmtime/blob/v48.0.8/crates/c-api/README.md)
using the required CMake and Rust toolchain. From the upstream source root:

```sh
cmake -S crates/c-api -B target/c-api --install-prefix /absolute/path/to/artifacts
cmake --build target/c-api
cmake --install target/c-api
```

This creates matching headers and a full static library in `artifacts`.
Substitute that verified pair in the native build helper when choosing this path.

| Source archive | SHA256 |
| --- | --- |
| `https://github.com/bytecodealliance/wasmtime/archive/7b6c29ec3e9a49c97da231665cbd8eead9ccbda0.tar.gz` | `2da7245c22acba8b0c629542bb681aa592c8bdf644f0b7e74fac6086d32d165a` |

## Platform evidence

Release archives exist for arm64 and x86_64 on macOS and Linux. Availability does
not establish execution coverage. See the [README](../../README.md#build-from-source)
for measured targets.

The full macOS arm64 static library is 41,452,056 bytes. Measure linked fh size
separately because linking and stripping change distribution size.

## macOS arm64 binary notices

`inventory-aarch64-macos.json` lists all 235 package/version pairs in the locked
Wasmtime C API normal/build graph for `aarch64-apple-darwin`, with default features
and logging. Each entry identifies its source archive and the SHA-256 of its
retained texts in `dependencies/`. All 506 collected dependency text files are
included. This includes build tools and optional source conservatively; it does
not assert that every listed package survives linking.

The collection retains nested native and data notices, including ring's
BoringSSL and other-bits terms, Zstandard's BSD-3-Clause alternative, encoding_rs
and WHATWG notices, ICU Unicode data and webpki-roots' CDLA-Permissive-2.0 terms.
Alternative license files remain together as upstream supplied them. Zstandard
is distributed under its BSD alternative. The presence of another alternative's
text does not select it.

The official C API tarball's SHA-256 is listed above. Its full static library has
SHA-256 `efe4e9540d160f30f79c755e8efa229327c2577bbecf4e55f5c6cd523a1e2fed`.
[The publication job](https://github.com/bytecodealliance/wasmtime/actions/runs/40931741546/job/123651665020)
downloaded artifacts from CI run `40926215694` for the pinned source commit.
[That run's macOS arm64 release job](https://github.com/bytecodealliance/wasmtime/actions/runs/40926215694/job/123632425529)
installed Rust 1.97.0 (`2d8144b7880597b6e6d3dfd63a9a9efae3f533d3`), used the
precompiled target standard library, and built the full C API with release LTO,
`panic=abort` and forced unwind tables. Its C API invocation did not rebuild std.

All 372 compiler-builtins objects in the Wasmtime archive, including C and
assembly objects, match byte-for-byte the objects in the official
`rust-std-1.97.0-aarch64-apple-darwin` distribution. Its tarball SHA-256 is
`df26b872f1bbcc5cd700eacb76231d6ba97aeda76ccd44f5b7de3db3757a38ee`.
The remaining 52 objects are one Rust LTO object, ring native objects, Zstandard
native objects and Wasmtime's `gdbjit.c`. No objects are omitted from this count.
The Rust source commit embedded in the archive matches the release job.

`rust-1.97.0/` retains the complete generated `COPYRIGHT-library.html` from the
official Rust compiler distribution, Rust copyright and license texts, and
source annotations. The compiler distribution tarball SHA-256 is
`53e339f16382bb348566f648d01775797e038fdd6bfc6ddd8859c5a0eac09f68`.
Compiler-builtins and libm license texts and source copyright blocks are retained
from that same Rust commit. LLVM compiler-rt license and credits are retained
from its `src/llvm-project` submodule commit
`08c84e69a84d95936296dfcab0e38b34100725d5`. Compiler-builtins uses
MIT AND Apache-2.0 WITH LLVM-exception, including its identified third-party
portions. These runtime notices supplement the library notice document.

The notice collection includes the complete resolved source closure rather than
subtracting code or generated data that a linker might discard. Ring assembly,
Zstandard, Cranelift generators, trust anchors, Unicode tables and Rust runtime
support therefore retain their notices even if unused in a particular fh link.
There is no claim of a minimal surviving-code inventory.

The macOS arm64 fh build uses Zig 0.16.0 and its standard library/compiler runtime
under the retained `../zig/LICENSE`. It targets macOS 13.0. Inspection of the
linked executable shows `/usr/lib/libSystem.B.dylib` as its sole dynamic library;
Apple system libraries are supplied by macOS, not copied into the archive.
The macOS binary does not statically bundle Apple's libc or LLVM libunwind.
Guest Wasm source and package notices remain alongside the guest modules.
