# Releasing fh

Install the macOS arm64 release (macOS 13 or newer):

```sh
curl -fsSL https://github.com/Maatskappy/fh/releases/latest/download/install.sh | sh
```

Only macOS arm64 binaries are offered. Other platforms use the [source build](../README.md#build-from-source). The commands below build local archives and upload nothing.

Use exactly Zig 0.16.0, Python 3 and Git from a source checkout. To isolate Zig caches, set `ZIG_LOCAL_CACHE_DIR` and `ZIG_GLOBAL_CACHE_DIR`. Otherwise Zig uses its ordinary cache configuration.

## Build release archives

Build and inspect the archives before any separate publication decision:

1. Set `.version` in `build.zig.zon`. The build and `fh --version` use this single application version.
2. Run the release script:

   ```sh
   ./scripts/release.sh --out release --targets aarch64-macos
   ```

   The script runs `zig build test-loops-native` and `python3 patches/fx/verify.py` once. Either failure stops it. It then builds the same bundle as `scripts/build.sh`, once per selected target. Retain the complete `licenses/` directory in each archive. A supplied version must match source. It cannot relabel the archive.
3. Test the installer:

   ```sh
   ./scripts/test-install.sh release
   ```

   This serves the folder locally and pipes `install.sh` into `sh`, plus `dash` and `bash` where available. It checks installed `fh --version` and `fh --help`. It also verifies that damaged archives, unpublished versions, unsupported systems and cut-off scripts install nothing.
4. Review archives, notices and measured platform results.

For a fast version-tooling regression check, run `python3 -m unittest discover -s tests/native -p release_tooling_test.py`. It checks canonical version lookup, requested-version mismatch rejection and executable-version validation. Its synthetic compiler does not validate native binaries.

## What is built

The script can build these target archives. Only `aarch64-macos` is published:

| Target | Zig target | Archive |
| --- | --- | --- |
| `aarch64-macos` | `aarch64-macos` | `fh-VERSION-macos-aarch64.tar.gz` |
| `x86_64-macos` | `x86_64-macos` | `fh-VERSION-macos-x86_64.tar.gz` |
| `x86_64-linux` | `x86_64-linux-gnu` | `fh-VERSION-linux-x86_64.tar.gz` |
| `aarch64-linux` | `aarch64-linux-gnu` | `fh-VERSION-linux-aarch64.tar.gz` |

Use `--targets "aarch64-macos x86_64-linux"` for a subset. Each target selects a hash-pinned Wasmtime 48.0.8 static archive.

Linux uses GNU ABI and dynamically linked system libraries, rather than a fully static musl binary. macOS binaries require macOS 13 or newer.

Cross-linking does not establish target execution support. Tests run on the build machine only. The script checks a built executable's version when its target matches the host. See the README for [tested platforms](../README.md#status).

The output folder contains:

| Output | Contents |
| --- | --- |
| One archive per target | A single folder named like the archive, with the `dist/` layout. |
| `SHA256SUMS` | One `<sha256>  <file>` line per written archive. Verify with `shasum -a 256 -c SHA256SUMS`. |
| `manifest.json` | Version, and each target's filename, SHA-256 and size. |

The bundle keeps `fh` beside `docs/`, `lib/`, `loops/`, `skills/`, `scripts/`, `examples/`, `packages/` and `licenses/`. It also includes README, root LICENSE and NOTICE, CONTRIBUTING and SECURITY. Keep the folder whole. fh finds guides and schemas beside its binary.

Each run first removes previous `fh-*.tar.gz`, `SHA256SUMS` and `manifest.json` from the output folder. `release/` is git-ignored.

Packing uses fixed order, owners, modes and timestamps. Timestamps use `SOURCE_DATE_EPOCH` or the last commit time. Identical bundle bytes produce identical archives. Native builds are not established as reproducible across machines or toolchains. Keep checksums with their exact archives.

## Hosting

GitHub Releases on [Maatskappy/fh](https://github.com/Maatskappy/fh/releases) hosts the installer and archives. Upload `install.sh`, the archive, `SHA256SUMS` and `manifest.json` to the version tag `vVERSION` after review and release authorization. Build from the merged commit before tagging. Repository tools and CI upload nothing.

`FH_VERSION=VERSION` (or `vVERSION`) selects an explicit version. `FH_INSTALL_BASE` overrides the release root, which defaults to `https://github.com/Maatskappy/fh/releases`. A mirror must serve the same URL layout:

```text
latest/download/SHA256SUMS          (may redirect to the selected tag)
download/vVERSION/SHA256SUMS
download/vVERSION/manifest.json
download/vVERSION/fh-VERSION-macos-aarch64.tar.gz
```

For `latest`, the installer reads the version from the macOS arm64 archive name in `SHA256SUMS`. It then fetches `SHA256SUMS` again and downloads the archive from that fixed version tag. A new latest release cannot mix those two files. Checksums detect corruption; use a release host you trust.

## Signing and notarization

The macOS arm64 binary is ad-hoc signed by Zig. It is not Developer ID signed or notarized. Release notes state this and record the OS and architecture used for the install and first-Loop checks.

The curl installer writes downloaded bytes without adding a browser quarantine attribute. If you download through a browser and macOS blocks the extracted binary, follow [Apple's instructions for opening a trusted app](https://support.apple.com/en-us/102445). Verify the release checksum before allowing it.

## Removing old versions

Delete unwanted installed version folders from `~/.fh/app/`. The installer keeps every installed version there.

## What the installer does

The installer is POSIX sh and requires:

- curl or wget.
- tar.
- sha256sum, shasum or openssl.

It accepts only macOS arm64. It downloads `SHA256SUMS`, selects the machine's archive and downloads it. A mismatched SHA-256 stops installation without installing anything.

After verification, it unpacks into `${FH_INSTALL_DIR:-~/.fh/app}/VERSION/`. It runs the new `fh --version` once, then renames a new link over `${FH_BIN_DIR:-~/.local/bin}/fh`. It never uses sudo or edits shell profiles.

`~/.fh` also holds the default profile's settings, sign-in, packages, native runs and sessions. Profile records use fixed names other than `app`. Bundles do not collide with them. The installer writes nowhere else in that profile. Setting `FH_DATA_DIR` moves the profile, while bundles still default to `~/.fh/app`.
