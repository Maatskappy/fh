# Source publication and binary status

Build fh from [source](../README.md#build-from-source). Public binaries are not published yet. [Maatskappy/fh](https://github.com/Maatskappy/fh) hosts the source, ongoing development and pull requests.

fh is experimental. fh-owned material uses [Apache-2.0](../LICENSE). Included third-party material keeps its own terms and [notices](../NOTICE).

The source tree retains:

- Paired Wasm guest sources and artifacts, with package-local notices.
- fx provenance records.
- Dependency license texts.

The build fetches native Wasmtime archives. They are not committed in the source tree. A binary distribution still needs a complete static dependency notice inventory before publication.

[Local archive tooling](releasing.md) uploads nothing. The installer requires an explicit release base while binary hosting is unavailable. That guide also explains signing and notarization. The [README](../README.md#status) records measured platform coverage.

Follow the [contribution process](../CONTRIBUTING.md) for changes and [SECURITY](../SECURITY.md) for private vulnerability reports or its fallback. Preserve attribution. Use [privacy guidance](privacy.md#sharing-diagnostics) to remove credentials and private content from diagnostics.
