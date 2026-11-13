# wasm32-wasi-json/1

Use this profile to execute retained WebAssembly with JSON input and output.
The restrictions below define the guest's authority and resource bounds.

A code step selects this built-in contract with `"runtime": "wasm32-wasi-json/1"` and a package-local `file` naming portable core WebAssembly bytes. There is no runtime profile to register, Docker dependency, external Wasm command, source compilation, or dependency installation at execution time. In loops/0.4, use an empty `dependencies.runtimes` map unless other source steps need runtimes. The package snapshot retains and hashes both artifacts and any included authoring source.

The module exports `memory` (one module-defined wasm32 linear memory) and `_start: () -> ()`. fh serializes the step's JSON input to stdin. stdout must contain exactly one UTF-8 JSON value, which passes the existing strict JSON parser and step output schema. A normal return or `proc_exit(0)` succeeds. A trap, nonzero exit, invalid JSON/schema, output overflow, cancellation, or deadline failure commits no output. stderr is a separate bounded diagnostic stream, never JSON output; it is not persisted in the run record. Buffered stream bytes are discarded on failure. A guest cannot hide overflow by handling a write error.

## Imports and authority

Only these function imports from `wasi_snapshot_preview1` are accepted, with exactly these signatures. All imports are inspected, even unused ones. Table, memory, global, and other-module imports are refused.

| Imports | Parameters | Results |
| --- | --- | --- |
| `fd_read`, `fd_write` | i32, i32, i32, i32 | i32 |
| `fd_seek` | i32, i64, i32, i32 | i32 |
| `fd_fdstat_get`, `args_get`, `args_sizes_get`, `environ_get`, `environ_sizes_get` | i32, i32 | i32 |
| `fd_close` | i32 | i32 |
| `proc_exit` | i32 | none |

stdin is an owned in-memory byte vector. stdout/stderr use bounded callbacks. The only descriptors are these three streams; seeking does not grant files. argv is exactly `["fh-wasm"]`, environment is empty, and no directories, host descriptors, sockets, network, clocks, or randomness are inherited or supplied. Calls such as `path_open`, `clock_time_get`, and `random_get` cause preflight refusal rather than a late runtime error.

## Features and resource limits

The pinned engine supports ordinary wasm32 WASI compiler output: core numeric instructions, mutable globals, sign extension, saturating conversions, bulk memory, multi-value, reference types, and extended constant expressions. Standard reference types permit the table-index encoding used by normal WASI libc. Typed function references, GC, threads/shared memory, SIMD/relaxed SIMD, multiple memories, memory64, tail calls, wide arithmetic, branch hints, exceptions, custom page sizes, stack switching, and components are disabled. Packages are never deserialized as engine-native executable artifacts.

There is one instance and one memory, bounded by the source-container memory constant: 128 MiB. At most one module-defined `funcref` table is permitted; its element limit is 128 MiB divided by native pointer size (16,777,216 on supported 64-bit targets). This follows the pinned engine's [function-table slot representation](https://github.com/bytecodealliance/wasmtime/blob/v48.0.8/crates/wasmtime/src/runtime/vm/table.rs). Imported tables and `externref` tables are refused. These are separate guest allocation ceilings, not a combined whole-process RSS guarantee: compilation, code, metadata, stacks, and engine allocations are outside them. The engine's store limiter also refuses growth past these ceilings.

The existing run limits bound input/stdout and stderr (`max_output_bytes`, `max_diagnostic_bytes`), with no added instruction/fuel or retry budget. Every artifact is compiled and validated, its import signatures and declaration envelope checked, and linking resolved with `instantiate_pre` before any inference adapter callback. Checking never instantiates or executes a start function. Initial memory/table declarations are checked even when not exported.

Each invocation owns a private engine and store. Epoch interruption and allocation limits are configured before instantiation, including a Wasm start section. A watcher observes that run's existing cancellation flag and deadline and is joined before store/engine teardown. It cannot interrupt a sibling store. Cancellation/deadline are checked before and after compilation and before accepting output. Guest epoch interruption does **not** preempt host compilation/validation.

## Identity and recovery

Attempts retain additive `code_execution` metadata: `artifact_sha256`, `profile`, `engine` (`wasmtime`), and `engine_version` (`48.0.8`). It survives execution failure when an attempt is available. Public `fh get` presents `code_executions` with step/path/iteration/status and execution identity, without exposing attempt inputs. Pure Wasm creates no external effect receipt. Existing accounting, unknown effects, immutable package/binding checks, explicit whole-run retry, and agent-driver replay rules continue to apply; metadata never authorizes replay.

## Authoring and verification

Use the [editable examples and Zig rebuild recipe](../code-runtimes.md) to author artifacts. Tests cover an ordinary C `scanf` and `printf` tool compiled with Zig's WASI libc, alongside adversarial modules.

Normal tests load checked-in artifacts without a compiler or external Wasm runtime. See [Wasmtime notices](../../licenses/wasmtime/README.md) for native dependency provenance and licensing.
