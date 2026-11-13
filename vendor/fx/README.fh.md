# Pinned native fx source in Fasthands

fh builds on the actual [vercel-labs/fx](https://github.com/vercel-labs/fx) CLI. The pinned revision is `4d966e272cfc4296cdf703f409480088cf2e72ba`, upstream 0.0.13. Original Apache-2.0 licensing and third-party notices remain intact.

fx supplies the terminal, conversation worker, tools, Codex login and providers. Root `build.zig` combines it with the native Zig Loop engine in `native/loops/`. fh implements chat and direct Loop commands without a Node application worker or custom OAuth client.

Optional source runtimes use registered Docker images. Retained Wasm uses the embedded Wasmtime library. Building and running the application need no Node or npm.

## Build and verify

Use Zig **0.16.0** and run `./scripts/build.sh` from the checkout root. Keep the complete `dist/` assets beside the executable. See the root [README](../../README.md) for setup and verified platform limits.

Run `python3 patches/fx/verify.py` from the checkout root to verify provenance. `UPSTREAM_FILES.json` retains hashes for all 637 original files. The [integration guide](../../patches/fx/README.md) defines the patch boundary, additions, notices, reconstruction checks and presentation checks.
