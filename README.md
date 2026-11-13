# fh

fh is a native Zig terminal agent for creating and running reusable **Loops**. A Loop combines instructions, schemas and saved code. fh checks data, carries feedback between bounded attempts and saves each result.

## Install on macOS arm64

Requires macOS 13 or newer:

```sh
curl -fsSL https://github.com/Maatskappy/fh/releases/latest/download/install.sh | sh
~/.local/bin/fh --version
```

The installer verifies SHA-256, keeps the complete bundle in `~/.fh/app/VERSION/`, and links `~/.local/bin/fh`. It prints a PATH command if needed. The binary is ad-hoc signed and is not notarized. See [release installation](docs/releasing.md#signing-and-notarization) if macOS blocks it.

Binary releases are offered for macOS arm64 only. Other platforms use the source build below.

## Build from source

Build fh with these tools:

| Tool | Requirement |
| --- | --- |
| Zig | Exactly **0.16.0**. |
| Python | Python 3 for development checks. |
| Git | Available on your PATH. |

The build fetches a hash-pinned native Wasmtime library. Building fh and running the first example require no Node, npm, Docker or Wasmtime CLI.

```sh
git clone https://github.com/Maatskappy/fh.git
cd fh
zig version                    # must print 0.16.0
./scripts/build.sh
./dist/fh --version
```

The script runs native Loop tests and the fx provenance audit. It then builds the complete optimized `dist/` bundle. Keep that folder together when moving it. Add the folder to PATH to use `fh` anywhere.

## First Loop: no credentials

Run the bundled Wasm example from the checkout root after building. For an installed release, replace `./dist` with `~/.fh/app/VERSION` (the version printed by `fh --version`). Use a new private profile. Keep inputs outside the package because every package file contributes to its identity.

```sh
fh_profile="$(mktemp -d "${TMPDIR:-/tmp}/fh.XXXXXX")" &&
FH_DATA_DIR="$(cd "$fh_profile" && pwd -P)" &&
export FH_DATA_DIR &&
printf '%s\n' '{"number":2}' > "$FH_DATA_DIR/input.json" &&
./dist/fh check ./dist/loops/increment-wasm --json &&
./dist/fh run ./dist/loops/increment-wasm --input "$FH_DATA_DIR/input.json" --json
```

The expected results are:

| Command | Result |
| --- | --- |
| `check` | `ok:true` |
| `run` | `status:"completed"` and output `{"answer":3}` |

The run executes the bundled Wasm artifact without a model request or source-runtime setup. Use the returned run ID with `./dist/fh get RUN_ID --json` to read the saved result.

See [runtime recipes](docs/code-runtimes.md) to edit and rebuild a Loop. See [local storage](docs/privacy.md#local-storage) to manage the disposable profile.

## Chat and model setup

Run `./dist/fh` to set up model access and start chat. These commands also configure access:

```sh
./dist/fh setup             # AI access, optionally Jev
./dist/fh setup ai          # change AI access
./dist/fh login codex       # native fx Codex sign-in
./dist/fh setup jev         # optional typed decision provider
./dist/fh status
```

Choose native ChatGPT/Codex login, a Vercel AI Gateway key, or an OpenAI-compatible endpoint with a key and model. See [provider requirements and Jev](docs/model-setup.md#model-setup) and [credential storage](docs/privacy.md#local-storage).

After setup, try the [hello Loop](loops/hello/README.md): run `fh check ./loops/hello`, then `fh run ./loops/hello`. Use `fh run ./loops/hello --driver agent` to have an outside agent supply its steps.

## Use and remix Loops

Review a package, install it into your profile, then use its name from any directory:

```sh
fh add ./my-loop
fh add OWNER/REPO/PATH@REF
fh list
fh check my-loop --json
fh run my-loop --input input.json --json
fh update my-loop
fh remove my-loop
```

You can also fetch, inspect, install and run a GitHub package in one command:

```sh
fh run OWNER/REPO/PATH[@REF] --input input.json
```

fh shows the inspection and asks before installing. See the [package guide](docs/packages.md) for confirmation in scripts, immutable versions and local paths.

In chat, `/check` and `/run` operate on Loops. `/resume` reopens conversations. See [chat commands](docs/model-setup.md#chat-commands) for context handling.

Choose a guide for your next task:

| Task | Guide |
| --- | --- |
| Write a Loop | [Authoring](docs/loops.md) |
| Grant files and commands. Recover effects | [Workspace Loops](docs/workspace-loops.md) |
| Run source or rebuild Wasm | [Code runtimes](docs/code-runtimes.md) |
| Run cases, compare labels or retry | [Batch and evaluation](docs/batch-evaluation.md) |
| Use a browser or capture evidence | [Browser guide](docs/browser-capture.md) |
| Bind typed decisions and iteration feedback | [Decision gate](loops/decision-gate/README.md), [warm context](loops/warm-context/loop.json), [examples](loops) |
| Supply inference from an outside agent | [Agent drivers](docs/contracts/loops-0.3.md) |
| Check development receipts | [Own-use workflow](docs/fh-own-use.md) |

Portable definitions use the [0.1 contract](docs/contracts/loops-0.1.md) and [JSON and feedback addendum](docs/contracts/loops-0.1-addendum.md). Later versions add [0.2 decisions](docs/contracts/loops-0.2.md), [0.3 parallel work and agent steps](docs/contracts/loops-0.3.md), and [0.4 runtime prerequisites](docs/contracts/loops-0.4.md).

The [Wasm profile](docs/contracts/wasm32-wasi-json-1.md) defines artifact restrictions. See [validation and results](docs/loops.md#noninteractive-cli) for supported schemas and the difference between completed execution and a domain verdict.

Agent guides are [using-fh](skills/using-fh/SKILL.md) and [author-loop](skills/author-loop/SKILL.md). Install them with `python3 dist/scripts/install-skills.py` from the checkout. Use `--dest PATH` for another skill directory, then refresh the agent host's inventory. Existing skill folders are never replaced implicitly.

## Status

fh is experimental. Interfaces and package formats are evolving. Independent cross-runner compatibility is unverified.

Platform evidence is limited to these checks:

| Platform | Evidence |
| --- | --- |
| macOS arm64 | Tested with Zig 0.16.0. CI checks the native app, Loop tests, chat tests, portable examples, complete bundle and fx provenance. |
| Linux GNU arm64 | Tested in an offline Ubuntu ARM64 container for Wasm check, run and get. Local installation. And read-only workspace registration and checks. |
| Linux GNU x86_64 | Cross-linked. Execution unverified. |
| macOS x86_64 | Execution unverified. |

## Contribute

Open development work and pull requests in [Maatskappy/fh](https://github.com/Maatskappy/fh). Small contributions are welcome. Read [CONTRIBUTING](CONTRIBUTING.md) and [SECURITY](SECURITY.md).

See [publication status](docs/publication.md) for source and binary availability. See [release builds](docs/releasing.md) for local archive tooling.

fh builds on the actual [fx CLI](https://github.com/vercel-labs/fx). It uses fx's terminal, conversation worker, tools, native Codex login and model providers.

| Material | Version and terms |
| --- | --- |
| fh-owned additions | [Apache-2.0](LICENSE). Retain [NOTICE](NOTICE) and third-party license texts. |
| fx | `4d966e272cfc4296cdf703f409480088cf2e72ba` (0.0.13). Original [license](vendor/fx/LICENSE) and [notices](vendor/fx/THIRD_PARTY_NOTICES.md) retained. The [provenance check](patches/fx/README.md) reconstructs all 637 originals and verifies the integration patch. |
| Wasmtime | The build fetches and statically links 48.0.8 under Apache-2.0 WITH LLVM-exception. The complete [license](licenses/wasmtime/LICENSE) and [macOS arm64 dependency notices](licenses/wasmtime/README.md#macos-arm64-binary-notices) are retained. |
