# Editable source and portable Wasm

Use [increment-source](../loops/increment-source/loop.json) to edit Node code, or [increment-wasm](../loops/increment-wasm/loop.json) to run a retained binary. Both transform `{"number": 2}` into `{"answer": 3}` without inference. Both accept integers from -1,000,000 through 1,000,000.

Each directory is self-contained. Copy it whole to remix it. The source package retains a Node module. The Wasm package retains Zig source and its compiled binary.

## Run the retained artifact

Run Wasm with fh alone. Checking and running use no compiler, Docker, Node, Python, Rust or Wasmtime CLI. From a checkout or complete bundle:

```sh
fh_profile="$(mktemp -d "${TMPDIR:-/tmp}/fh.XXXXXX")" &&
FH_DATA_DIR="$(cd "$fh_profile" && pwd -P)" &&
export FH_DATA_DIR &&
printf '%s\n' '{"number":2}' > "$FH_DATA_DIR/input.json" &&
fh check ./loops/increment-wasm --json &&
fh run ./loops/increment-wasm --input "$FH_DATA_DIR/input.json" --json
# Retrieve the returned run ID with: fh get RUN_ID --json
```

A fresh profile needs no source runtime registration. The [manifest](../loops/increment-wasm/loop.json) declares:

| Field | Value |
| --- | --- |
| `format` | `"loops/0.4"` |
| `dependencies` | `{"runtimes":{}}` |
| Code `runtime` | `"wasm32-wasi-json/1"` |
| Code `file` | `"increment.wasm"` |
| Code `requires` | `[]` |
| Input binding | `/input` |
| Output binding | `/steps/increment/output` |

The manifest includes both schemas. `get.code_executions` identifies the artifact SHA256, profile and engine. Successful pure Wasm has no external effects and zero model dispatches.

Other capabilities need separate setup:

| Capability | Authority |
| --- | --- |
| Optional Node and Python | Explicitly registered Docker runtimes with already installed immutable images. |
| [Workspace commands](workspace-loops.md) | Host commands under a separate workspace grant. |
| [Browser grants](browser-capture.md) | Real browser interaction and network access. |

Read the relevant guide before enabling a capability.

## Choose source explicitly

Select `runtime:"node"` and `file:"increment.mjs"` as [increment-source](../loops/increment-source/loop.json) does. Its prerequisite declaration is:

```json
"dependencies": {
  "runtimes": {
    "node": { "min_version": "24.0.0", "modules": ["assert/strict"] }
  }
}
```

Runtime modules are availability requirements:

| Runtime | Module names |
| --- | --- |
| Node | Builtins without `node:`, such as `assert/strict`, `fs` and `fs/promises`. Imports in source may use `node:assert/strict`. |
| Python | Standard-library names such as `json`. |

These declarations install no npm or pip dependencies. Every nested source step needs an entry. Unused declarations are checked too. Do not put Wasm or `fh-workspace/1` in the map. See the [0.4 contract](contracts/loops-0.4.md) and [schema](../packages/loops-contract/loop-0.4.schema.json).

Register an already installed runtime using an existing socket and immutable image digest:

```sh
fh setup runtime node --socket /absolute/docker.sock --image IMAGE@sha256:DIGEST --version 24.18.0
fh check ./loops/increment-source --json
fh run ./loops/increment-source --input "$FH_DATA_DIR/input.json" --json
```

Supply your actual image and version. fh never pulls images or installs dependencies. Checks verify configured prerequisites, then actual probed versions and modules, before any package code or model request. Only the fixed runtime probe executes.

| Test | Expected issue |
| --- | --- |
| Missing Node installation | `check` exits 2 with `ok:false`, naming `runtimeProfiles.node` and the setup command. |
| Node 24 profile with copied package minimum changed to `25.0.0` | `dependencies.runtimes.node.min_version`, expected minimum and actual version. Copy outside the original directory first. |
| Nonexistent builtin | `.modules`. |
| Source error | Existing source error code remains intact. |

The package's `runtime` and `file` select one implementation. To change it, edit both fields and matching dependencies. Retain the intended implementation and schema. An extra source file alone does not run. There is no runner preference, fallback, translation or automatic build.

## Remix and rebuild (authors only)

Edit steps, bindings, repeat, schemas, instructions and prompt files as ordinary package content. Changes to `increment.mjs` run on the next source invocation. Editing `increment.zig` changes package identity, but the executed Wasm stays the same until rebuilt.

Use exactly Zig **0.16.0** from the checkout or bundle root:

```sh
zig version
zig build-exe loops/increment-wasm/increment.zig -target wasm32-wasi -O ReleaseSmall -fno-entry -rdynamic -femit-bin=loops/increment-wasm/increment.wasm
zig build-exe loops/workspace-check/suggest.zig -target wasm32-wasi -O ReleaseSmall -fno-entry -rdynamic -femit-bin=loops/workspace-check/suggest.wasm
chmod 644 loops/increment-wasm/increment.wasm loops/workspace-check/suggest.wasm
shasum -a 256 loops/increment-wasm/increment.zig loops/increment-wasm/increment.wasm loops/workspace-check/suggest.zig loops/workspace-check/printable.zig loops/workspace-check/suggest.wasm
```

The source imports WASI streams explicitly and exports `_start: () -> ()`. It reads UTF-8 JSON stdin and writes one JSON stdout value. See the [profile contract](contracts/wasm32-wasi-json-1.md) for imports, signatures, features and bounds.

Wasm has no ambient filesystem, host environment, network, clock or randomness. Linear memory is bounded to 128 MiB. Whole-process RSS is not. Preflight rejects invalid artifacts and unsupported imports before callbacks or guest execution. Diagnostics name the file, profile and actual reason. Even an unreachable `random_get` import is forbidden.

To try a behavior change:

1. Copy `increment-wasm`.
2. Change `input.number + 1` to `input.number + 2` in the copy.
3. Rebuild copied source to the copied artifact using the same command.
4. Check and run the copy. Input 2 should return answer 4.

A rebuild changes the artifact SHA256 and package digest. Without it, output stays 3 while the edited-source package digest changes. Increase the version before installing a changed release. Installed bytes are immutable.

Keep inputs, build logs and outputs outside the package. Execution and ordinary artifact tests run no build hook.

The following hashes identify retained files. To verify source correspondence, rebuild with the specified compiler and command, compare the binary and test output:

```text
b181ae9ec3710137f56d83b542dc41b51436ea3d222c3e5835ce463a2e6b398c  loops/increment-wasm/increment.zig
f336cf25a49df0f6bf7806cf7a575a48e16f3e46ae019f4cbcba454d03812ba1  loops/increment-wasm/increment.wasm
4959b0000ec7e253a857c0b36b4f1a0d87aaae824f8d1ec44a0c2d86c1f1ff3b  loops/workspace-check/suggest.zig
f6fcf5a7715f7f987aff9529cf5d39286937c9a6a422b90cc6223fda282caa3c  loops/workspace-check/printable.zig
38a3931e3c4d9103c4b66f9e7127517a602be50662968404b8fdcfd4acbb5f18  loops/workspace-check/suggest.wasm
```

## Workspace-check compatibility

Bundled workspace-check 0.2.0 executes its saved Wasm on an explicit bounded snapshot. Its independent Python reference is `tests/native/fixtures/workspace-check/suggest-v0.1.py`, outside the installed package.

The shallow recognizer lists 0.2, 0.3 and 0.4 declarations. Listing does not establish full validation.

Unicode cleaning uses retained `printable.zig`, so execution needs no Python. The table comes from Python 3.12.3's Unicode 15.0.0 `str.isprintable` and `str.isspace` properties. It covers code points 0 through 0x10FFFF as contiguous nonprintable ranges.

Version 0.2.0 has these parser boundaries:

| Case | Difference |
| --- | --- |
| Extreme nesting | Python's recursive parser and Zig's iterative parser can classify it differently. |
| Unpaired surrogate escapes | Zig rejects malformed JSON. Python accepts the escapes, then cleaning replaces them. |

Compatibility fixtures independently label ordinary startup, malformed JSON, duplicate and nonfinite values, Unicode and controls, missing files, partial snapshots and bounded lists. They do not establish universal parser equivalence.

Authors can regenerate the table with `tests/native/fixtures/workspace-check/generate-printable.py` under Python 3.12.3 and Unicode 15.0.0. Then run `zig fmt loops/workspace-check/printable.zig`.

The generator used `mcr.microsoft.com/playwright@sha256:5b8f294aff9041b7191c34a4bab3ac270157a28774d4b0660e9743297b697e48`. fh does not fetch this author-only image. Other Python Unicode versions may classify newly assigned characters differently.

## Check the shipped examples

Run `zig build test-portable-examples` from the source checkout. CI uses the same check.

The harness executes retained artifacts with an empty child `PATH` and fresh profile. It checks:

- Synthetic startup and Unicode fixtures against independent expectations.
- Persisted output and zero model dispatches.
- Invalid-artifact diagnostics and missing source prerequisites.

Python runs the harness only. The child fh needs no source runtime or compiler.
