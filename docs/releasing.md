# Releasing fh

Use this guide to build local archives. The commands upload nothing. Public binaries are not published yet. See [publication status](publication.md).

Binary distribution still requires a complete static dependency notice inventory and validation on intended platforms.

Use exactly Zig 0.16.0, Python 3 and Git from a source checkout. To isolate Zig caches, set `ZIG_LOCAL_CACHE_DIR` and `ZIG_GLOBAL_CACHE_DIR`. Otherwise Zig uses its ordinary cache configuration.

## Build release archives

Build and inspect the archives before any separate publication decision:

1. Set `.version` in `build.zig.zon`. The build and `fh --version` use this single application version.
2. Run the release script:

   ```sh
   ./scripts/release.sh            # the version in the source, into release/
   ./scripts/release.sh 0.3.1 --out /some/folder
   ```

   The script runs `zig build test-loops-native` and `python3 patches/fx/verify.py` once. Either failure stops it. It then builds the same bundle as `scripts/build.sh`, once per target. A supplied version must match source. It cannot relabel the archive.
3. Test the installer:

   ```sh
   ./scripts/test-install.sh release
   ```

   This serves the folder locally and pipes `install.sh` into `sh`, plus `dash` and `bash` where available. It checks installed `fh --version` and `fh --help`. It also verifies that damaged archives, unpublished versions, unsupported systems and cut-off scripts install nothing.
4. Review archives, notices and measured platform results.

For a fast version-tooling regression check, run `python3 -m unittest discover -s tests/native -p release_tooling_test.py`. It checks canonical version lookup, requested-version mismatch rejection and executable-version validation. Its synthetic compiler does not validate native binaries.

## What is built

The script builds these target archives:

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

Supply an explicit `FH_INSTALL_BASE` to use the installer. Without it, installation fails before networking. The local test script supplies a loopback HTTP base. Repository tools and CI upload no releases.

A release base must serve this relative layout:

```text
VERSION/SHA256SUMS
VERSION/manifest.json
VERSION/fh-VERSION-OS-ARCH.tar.gz    (one per target)
latest/...                         (the same files for the chosen latest version)
```

For `latest`, the installer reads the version from the archive name in `SHA256SUMS`. Checksums detect corruption. You remain responsible for trusting the release base.

## Signing and notarization

Developer ID signing and notarization are not configured. Zig ad-hoc signs arm64 macOS executables. Gatekeeper may restrict downloads. A working local build does not establish that downloaded archives run elsewhere.

## Removing old versions

Delete unwanted installed version folders from `~/.fh/app/`. The installer keeps every installed version there.

## What the installer does

The installer is POSIX sh and requires:

- curl or wget.
- tar.
- sha256sum, shasum or openssl.

It accepts only macOS or Linux on arm64 or x86_64. It downloads `SHA256SUMS`, selects the machine's archive and downloads it. A mismatched SHA-256 stops installation without installing anything.

After verification, it unpacks into `${FH_INSTALL_DIR:-~/.fh/app}/VERSION/`. It runs the new `fh --version` once, then renames a new link over `${FH_BIN_DIR:-~/.local/bin}/fh`. It never uses sudo or edits shell profiles.

`~/.fh` also holds the default profile's settings, sign-in, packages, native runs and sessions. Profile records use fixed names other than `app`. Bundles do not collide with them. The installer writes nowhere else in that profile. Setting `FH_DATA_DIR` moves the profile, while bundles still default to `~/.fh/app`.
