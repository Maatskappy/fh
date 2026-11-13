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
