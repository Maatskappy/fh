# Contributing

Contribute a focused fix, example or documentation improvement through [Maatskappy/fh](https://github.com/Maatskappy/fh). Discuss substantial behavior, format or architecture changes with maintainers before implementing them.

Fork the repository and create a branch. In your pull request, explain the problem, resulting behavior and how to reproduce it. Include relevant check results and any skips. Keep PRs intended to merge ready for review while work continues.

Maintainers review and decide when to merge. Address their findings. Never commit credentials, private provider responses or private workspace content, or include them in public reports.

## Development

Use exactly Zig **0.16.0**, Python 3 for audit scripts and Git. Start with the [source build and first Loop](README.md#build-from-source). Run tests in a separate profile:

```sh
fh_profile="$(mktemp -d "${TMPDIR:-/tmp}/fh.XXXXXX")" &&
FH_DATA_DIR="$(cd "$fh_profile" && pwd -P)" &&
export FH_DATA_DIR &&
zig build check test-loops-native test-chat test-portable-examples &&
python3 patches/fx/verify.py &&
python3 -m unittest discover -s tests/provenance -p fx_verify.py &&
python3 -m unittest discover -s tests/native -p pr_feedback_triage_test.py &&
python3 -m unittest discover -s tests/native -p release_tooling_test.py &&
./scripts/build.sh
```

Native tests use fixtures, including local HTTP providers, without requiring model credentials. One conformance check uses local Node when available. Otherwise it reports a skip.

Read usage and obtain operator authorization before running live provider or browser checks. Keep credentials and grants out of disposable tests. A separate profile isolates records. Native commands still run with their host authority and inherited environment credentials.

Choose checks that cover your change:

| Change | Check |
| --- | --- |
| Embedded Wasm runtime | `zig build test-wasm` |
| Startup | `zig build test-startup` |
| Complete bundle and provenance | `./scripts/build.sh` |
| Unix sockets | `python3 tests/native/long_socket_path.py` |

The socket check stages source under a long path and runs `zig build test-sockets`. It checks socket identity and Docker socket path validation without a Docker daemon.

Keep inputs and results outside packages. Increase the package version when releasing changed installed bytes. See [runtime recipes](docs/code-runtimes.md) for optional source registration and explicit Wasm rebuilds.

## Architecture map

Find implementation areas in the source checkout using this table. Binary bundles contain selected docs and assets.

| Area | Source paths |
| --- | --- |
| Native CLI and fx composition | `fh_main.zig`, `native/loops_client.zig`, `vendor/fx/src/main.zig` |
| Package formats, validation and execution | `native/loops/package.zig`, `schema.zig`, `runner.zig`, `engine.zig` |
| Local run state and installation | `native/loops/store.zig`, `bindings.zig`, `installed.zig` |
| Source and Wasm runtimes | `native/loops/code.zig`, `dependencies.zig`, `wasm.zig`, `native/wasmtime_build.zig` |
| Workspace and browser capabilities | `native/loops/workspace.zig`, `workspace_read.zig`, `browser.zig`, `native/capture/` |
| Onboarding and credentials | `native/onboarding.zig`, `native/credentials.zig` |
| Native conversation and provider integration | `vendor/fx/src/core/`, `vendor/fx/src/fh_loop_infer.zig`, `native/conversation_prompt.md` |
| Contracts, examples and guides | `docs/contracts/`, `packages/loops-contract/`, `loops/`, `skills/` |
| Synthetic tests and fixtures | `native/loops/tests.zig`, `fh_tests.zig`, `tests/native/` |

Adjacent filenames share the first named directory unless a full path is given. Test observable contracts and regressions rather than mirroring implementation details.

## Provenance and licensing

Preserve upstream originals and `vendor/fx/UPSTREAM_FILES.json`. Before changing vendor code, read `patches/fx/README.md` in the checkout. Keep prominent modification notices, original attribution and the explicit inventory of patches and additions.

Regenerate the patch only from an audited base with `python3 scripts/update-fx-patch.py BASE`. Then run `python3 patches/fx/verify.py`. Do not weaken zero-fuzz reconstruction or presentation and renderer guards to pass verification.

For new third-party material, record its source, exact version or revision, license and modifications. Preserve notices for copied code, data, packages and bundled assets. Source and compiled artifacts both need provenance and notices. Matching hashes alone do not prove a source-to-binary build.

By submitting a contribution, you agree to license it under the same Apache-2.0 terms as fh-owned additions, with existing third-party terms preserved. Submit only work you have the right to contribute. No CLA is required. See [LICENSE](LICENSE), [NOTICE](NOTICE) and [privacy guidance](docs/privacy.md).
