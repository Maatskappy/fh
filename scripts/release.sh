#!/bin/sh
# Build the fh release archives for every supported target.
#
#   scripts/release.sh [VERSION] [--out DIR] [--targets "T1 T2 ..."]
#
# Writes into DIR (default: release/), one archive per target plus SHA256SUMS and
# manifest.json. Nothing is uploaded: see docs/releasing.md.
set -eu

all_targets="aarch64-macos x86_64-macos x86_64-linux aarch64-linux"

usage() {
  printf '%s\n' "usage: scripts/release.sh [VERSION] [--out DIR] [--targets \"$all_targets\"]" >&2
  exit 2
}
fail() {
  printf 'release: %s\n' "$*" >&2
  exit 1
}

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
invoked_from=$(pwd)
cd "$root"

version=
out=
targets=$all_targets
while [ $# -gt 0 ]; do
  case "$1" in
    --out) [ $# -ge 2 ] || usage; out=$2; shift 2 ;;
    --out=*) out=${1#--out=}; shift ;;
    --targets) [ $# -ge 2 ] || usage; targets=$2; shift 2 ;;
    --targets=*) targets=${1#--targets=}; shift ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) [ -z "$version" ] || usage; version=$1; shift ;;
  esac
done

# The build reads this same canonical package version for fh --version, titles and
# protocol handshakes. A requested version is a check, never an archive label.
source_version=$(python3 - <<'VERSION'
from pathlib import Path
import re
versions = re.findall(r'^\s*\.version\s*=\s*"([^"\n]+)"\s*,\s*$', Path('build.zig.zon').read_text(), re.M)
if len(versions) != 1:
    raise SystemExit('release: expected one .version in build.zig.zon')
print(versions[0])
VERSION
)
[ -n "$version" ] || version=$source_version
[ "$version" = "$source_version" ] || fail "asked for $version but this source builds fh $source_version. Change .version in build.zig.zon, then release."

[ -n "$out" ] || out=release
case "$out" in
  /*) ;;
  *) out=$invoked_from/$out ;;
esac

# Zig target for each release target. The pinned Wasmtime archives use the GNU ABI
# on Linux: the engine is static, while system libc remains dynamic. macOS gets an explicit
# target: without one Zig builds for this machine's own macOS version and newer only.
zig_target() {
  case "$1" in
    aarch64-macos) printf '%s\n' aarch64-macos ;;
    x86_64-macos) printf '%s\n' x86_64-macos ;;
    x86_64-linux) printf '%s\n' x86_64-linux-gnu ;;
    aarch64-linux) printf '%s\n' aarch64-linux-gnu ;;
    *) fail "unknown target $1 (known: $all_targets)" ;;
  esac
}
# Archive names read OS first: fh-VERSION-OS-ARCH.tar.gz.
bundle_name() {
  printf 'fh-%s-%s-%s\n' "$version" "${1#*-}" "${1%%-*}"
}
for target in $targets; do zig_target "$target" >/dev/null; done
[ -n "$targets" ] || fail "no targets given"

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) host=aarch64-macos ;;
  Darwin-x86_64) host=x86_64-macos ;;
  Linux-x86_64) host=x86_64-linux ;;
  Linux-aarch64 | Linux-arm64) host=aarch64-linux ;;
  *) host= ;;
esac

printf 'release: fh %s for: %s\n' "$version" "$targets"
printf 'release: running the test suite and the fx provenance audit first\n'
zig build test-loops-native
python3 patches/fx/verify.py

stage=$(mktemp -d "$root/.dist-release-XXXXXX")
cleanup() {
  rm -rf -- "$stage"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

for target in $targets; do
  name=$(bundle_name "$target")
  printf 'release: building %s (%s)\n' "$name" "$(zig_target "$target")"
  zig build bundle -Doptimize=ReleaseFast -Dtarget="$(zig_target "$target")" --prefix "$stage/$name"
  [ -f "$stage/$name/fh" ] || fail "$name has no fh binary"
  if [ "$target" = "$host" ]; then
    reported=$("$stage/$name/fh" --version </dev/null)
    [ "$reported" = "fh $version" ] || fail "the $target binary reports '$reported', expected 'fh $version'"
  fi
done

# Archives are written with fixed owners, modes, order and timestamps, so the same
# bundle always packs to the same bytes. The checksums and the manifest are computed
# from the archive files after they are written, never from the bundle folders.
epoch=${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || printf 0)}
mkdir -p "$out"
rm -f -- "$out"/fh-*.tar.gz "$out/SHA256SUMS" "$out/manifest.json"
names=
for target in $targets; do names="$names $target=$(bundle_name "$target")"; done
# shellcheck disable=SC2086
python3 - "$stage" "$out" "$version" "$epoch" $names <<'PY'
import gzip, hashlib, json, os, stat, sys, tarfile

stage, out, version, epoch = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
pairs = [item.split('=', 1) for item in sys.argv[5:]]


def entries(folder):
    for current, directories, files in os.walk(folder):
        directories.sort()
        yield current
        for name in sorted(files):
            yield os.path.join(current, name)


def pack(folder, name, destination):
    with open(destination, 'wb') as raw:
        with gzip.GzipFile(filename='', fileobj=raw, mode='wb', compresslevel=9, mtime=0) as zipped:
            with tarfile.open(fileobj=zipped, mode='w', format=tarfile.PAX_FORMAT) as archive:
                for path in entries(folder):
                    relative = os.path.relpath(path, folder)
                    arcname = name if relative == '.' else name + '/' + relative.replace(os.sep, '/')
                    info = archive.gettarinfo(path, arcname)
                    if not (info.isdir() or info.isreg()):
                        raise SystemExit('release: %s is neither a file nor a folder' % path)
                    executable = info.isdir() or os.stat(path).st_mode & stat.S_IXUSR
                    info.mode = 0o755 if executable else 0o644
                    info.uid = info.gid = 0
                    info.uname = info.gname = ''
                    info.mtime = epoch
                    if info.isreg():
                        with open(path, 'rb') as source:
                            archive.addfile(info, source)
                    else:
                        archive.addfile(info)


targets = []
for target, name in pairs:
    file_name = name + '.tar.gz'
    pack(os.path.join(stage, name), name, os.path.join(out, file_name))
    targets.append((target, file_name))

manifest = {'version': version, 'targets': {}}
lines = []
for target, file_name in targets:
    path = os.path.join(out, file_name)
    digest = hashlib.sha256()
    with open(path, 'rb') as written:
        for block in iter(lambda: written.read(1 << 20), b''):
            digest.update(block)
    manifest['targets'][target] = {'file': file_name, 'sha256': digest.hexdigest(), 'size': os.path.getsize(path)}
    lines.append('%s  %s\n' % (digest.hexdigest(), file_name))
    print('release: %s  %s  %d bytes' % (digest.hexdigest(), file_name, os.path.getsize(path)))

with open(os.path.join(out, 'SHA256SUMS'), 'w') as sums:
    sums.writelines(lines)
with open(os.path.join(out, 'manifest.json'), 'w') as handle:
    json.dump(manifest, handle, indent=2)
    handle.write('\n')
PY

printf 'release: wrote %s\n' "$out"
printf 'release: nothing was uploaded. See docs/releasing.md.\n'
