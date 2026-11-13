# Source publication and binary status

Install the macOS arm64 binary with the [one-line installer](../README.md#install-on-macos-arm64), or build fh from [source](../README.md#build-from-source). Other platforms have no published binaries. [Maatskappy/fh](https://github.com/Maatskappy/fh) hosts the source, ongoing development and pull requests.

fh is experimental. fh-owned material uses [Apache-2.0](../LICENSE). Included third-party material keeps its own terms and [notices](../NOTICE).

The source tree retains:

- Paired Wasm guest sources and artifacts, with package-local notices.
- fx provenance records.
- Dependency license texts.

The build fetches native Wasmtime archives. They are not committed in the source tree. The macOS arm64 bundle includes [Wasmtime dependency and Rust runtime notices](../licenses/wasmtime/README.md#macos-arm64-binary-notices), alongside the existing Zig and guest Wasm notices.

[Local archive tooling](releasing.md) uploads nothing. The installer defaults to GitHub Releases on Maatskappy/fh and verifies SHA-256. That guide also explains signing and notarization. The [README](../README.md#status) records measured platform coverage.

Follow the [contribution process](../CONTRIBUTING.md) for changes and [SECURITY](../SECURITY.md) for private vulnerability reports or its fallback. Preserve attribution. Use [privacy guidance](privacy.md#sharing-diagnostics) to remove credentials and private content from diagnostics.
