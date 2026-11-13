#!/bin/sh
# Check scripts/install.sh against a locally built release served over HTTP.
#
#   scripts/test-install.sh [RELEASE_DIR]
#
# RELEASE_DIR is the output of scripts/release.sh and must hold an archive for this
# machine. Without it, this builds the host target first (which runs the test suite).
# Everything is installed into a scratch folder; the real home folder is not touched.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
installer=$root/scripts/install.sh

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) target=aarch64-macos ;;
  Darwin-x86_64) target=x86_64-macos ;;
  Linux-x86_64) target=x86_64-linux ;;
  Linux-aarch64 | Linux-arm64) target=aarch64-linux ;;
  *) printf 'test-install: no fh build for this machine\n' >&2; exit 1 ;;
esac
platform=${target#*-}-${target%%-*}

scratch=$(mktemp -d "${TMPDIR:-/tmp}/fh-install-test.XXXXXX")
server=
cleanup() {
  [ -z "$server" ] || kill "$server" 2>/dev/null || true
  rm -rf -- "$scratch"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

passed=0
ok() {
  passed=$((passed + 1))
  printf 'ok %d - %s\n' "$passed" "$1"
}
not_ok() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

# With no explicit base the shipped installer must stop before even needing PATH
# tools or touching an install directory. No network client is available here.
mkdir -p "$scratch/unpublished/home"
if env -i PATH= HOME="$scratch/unpublished/home" /bin/sh "$installer" >"$scratch/unpublished/output" 2>&1; then
  not_ok "the installer accepted an absent release base"
fi
grep -q 'public binaries are not published yet' "$scratch/unpublished/output" || not_ok "no clear source-only publication error"
[ -z "$(ls -A "$scratch/unpublished/home")" ] || not_ok "the unpublished installer changed HOME"
ok "without an explicit base the installer stops before networking"

if [ $# -ge 1 ]; then
  release=$(CDPATH= cd -- "$1" && pwd)
else
  release=$scratch/release
  "$root/scripts/release.sh" --targets "$target" --out "$release"
fi
version=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["version"])' "$release/manifest.json")
archive=fh-$version-$platform.tar.gz
[ -f "$release/$archive" ] || not_ok "$release has no $archive"

# The served layout: releases/VERSION/ and releases/latest/ hold the same files, and
# the installer itself sits at /install. A second tree serves a damaged archive.
site=$scratch/site
mkdir -p "$scratch/tmp" "$site/releases/$version" "$site/releases/latest" "$site/damaged/$version"
for file in "$archive" SHA256SUMS manifest.json; do
  cp "$release/$file" "$site/releases/$version/$file"
  cp "$release/$file" "$site/releases/latest/$file"
done
cp "$installer" "$site/install"
cp "$release/SHA256SUMS" "$site/damaged/$version/SHA256SUMS"
python3 - "$release/$archive" "$site/damaged/$version/$archive" <<'PY'
import sys
data = bytearray(open(sys.argv[1], 'rb').read())
data[len(data) // 2] ^= 0xFF
open(sys.argv[2], 'wb').write(data)
PY

port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$site" >"$scratch/server.log" 2>&1 &
server=$!
url=http://127.0.0.1:$port
tries=0
until curl -fsS -o /dev/null "$url/install" 2>/dev/null; do
  tries=$((tries + 1))
  [ "$tries" -lt 50 ] || not_ok "the local server did not start: $(cat "$scratch/server.log")"
  sleep 0.1
done
printf '# serving %s on %s\n' "$release" "$url"

# run NAME SHELL [VAR=VALUE ...]: pipe the served installer into SHELL, as a user would.
run() {
  name=$1
  shell=$2
  shift 2
  mkdir -p "$scratch/$name/home"
  status=0
  curl -fsSL "$url/install" | env -i PATH="$PATH" HOME="$scratch/$name/home" TMPDIR="$scratch/tmp" \
    FH_INSTALL_BASE="$url/releases" FH_INSTALL_DIR="$scratch/$name/app" FH_BIN_DIR="$scratch/$name/bin" \
    "$@" "$shell" >"$scratch/$name/output" 2>&1 || status=$?
  sed "s/^/#   [$name] /" "$scratch/$name/output"
  return "$status"
}
installed_nothing() {
  [ ! -e "$scratch/$1/bin/fh" ] && [ ! -L "$scratch/$1/bin/fh" ] || return 1
  [ ! -d "$scratch/$1/app" ] || [ -z "$(ls -A "$scratch/$1/app")" ]
}

shells=sh
for candidate in dash bash; do
  if command -v "$candidate" >/dev/null 2>&1; then shells="$shells $candidate"; fi
done

for shell in $shells; do
  name=latest-$shell
  run "$name" "$shell" || not_ok "$shell: installing latest failed"
  bin=$scratch/$name/bin/fh
  [ -L "$bin" ] || not_ok "$shell: $bin is not a link"
  [ "$("$bin" --version)" = "fh $version" ] || not_ok "$shell: installed fh --version is not 'fh $version'"
  "$bin" --help >"$scratch/$name/help" || not_ok "$shell: installed fh --help failed"
  grep -q 'Usage: fh' "$scratch/$name/help" || not_ok "$shell: fh --help printed no usage"
  for bundled in docs/loops.md lib/packages/loops-contract/loop-0.1.schema.json skills/author-loop/SKILL.md loops licenses/fx/LICENSE; do
    [ -e "$scratch/$name/app/$version/$bundled" ] || not_ok "$shell: the bundle is missing $bundled"
  done
  [ -z "$(ls -A "$scratch/$name/home")" ] || not_ok "$shell: the installer wrote into the home folder"
  [ -z "$(ls -A "$scratch/$name/app" | grep -v "^$version\$" || true)" ] || not_ok "$shell: leftovers beside the installed version"
  grep -q "^Run fh to get started\.\$" "$scratch/$name/output" || not_ok "$shell: no closing line"
  grep -q 'is not on your PATH' "$scratch/$name/output" || not_ok "$shell: no PATH line for a folder that is not on PATH"
  ok "$shell: latest installs, fh --version and fh --help run through the link"
done

# Installing the same version again replaces the folder and the link in place.
name=latest-sh
before=$(ls -di "$scratch/$name/app/$version" | awk '{print $1}')
run "$name" sh FH_VERSION="$version" PATH="$scratch/$name/bin:$PATH" || not_ok "installing $version over itself failed"
after=$(ls -di "$scratch/$name/app/$version" | awk '{print $1}')
[ "$before" != "$after" ] || not_ok "reinstalling did not replace the bundle folder"
[ "$("$scratch/$name/bin/fh" --version)" = "fh $version" ] || not_ok "fh does not run after reinstalling"
[ -z "$(ls -A "$scratch/$name/app" | grep -v "^$version\$" || true)" ] || not_ok "reinstalling left folders behind"
[ -z "$(ls -A "$scratch/$name/bin" | grep -v '^fh$' || true)" ] || not_ok "reinstalling left files in the bin folder"
if grep -q 'is not on your PATH' "$scratch/$name/output"; then not_ok "PATH line printed although the bin folder is on PATH"; fi
ok "a named version installs over itself and replaces the link"

name=damaged
if run "$name" sh FH_INSTALL_BASE="$url/damaged" FH_VERSION="$version"; then not_ok "a damaged archive was installed"; fi
grep -q 'does not match its checksum' "$scratch/$name/output" || not_ok "a damaged archive was refused for another reason"
installed_nothing "$name" || not_ok "a damaged archive left files behind"
ok "a damaged archive is refused and nothing is installed"

name=missing
if run "$name" sh FH_VERSION=9.9.9; then not_ok "a version that does not exist was installed"; fi
installed_nothing "$name" || not_ok "a missing version left files behind"
ok "a version that is not published is refused"

name=unsupported
mkdir -p "$scratch/$name/fake"
printf '#!/bin/sh\necho Plan9\n' >"$scratch/$name/fake/uname"
chmod +x "$scratch/$name/fake/uname"
if run "$name" sh PATH="$scratch/$name/fake:$PATH"; then not_ok "an unsupported system was accepted"; fi
grep -q 'no build for Plan9' "$scratch/$name/output" || not_ok "an unsupported system was refused for another reason"
installed_nothing "$name" || not_ok "an unsupported system left files behind"
ok "an unsupported system is refused plainly"

name=occupied
mkdir -p "$scratch/$name/bin"
printf 'mine\n' >"$scratch/$name/bin/fh"
if run "$name" sh; then not_ok "a file that is not a link was replaced"; fi
[ "$(cat "$scratch/$name/bin/fh")" = mine ] || not_ok "a file that is not a link was changed"
ok "an existing fh that is not a link is left alone"

# Half a script must run nothing: main is only called on the last line.
name=truncated
mkdir -p "$scratch/$name/home"
size=$(wc -c <"$installer")
head -c $((size * 3 / 4)) "$installer" | env -i PATH="$PATH" HOME="$scratch/$name/home" TMPDIR="$scratch/tmp" \
  FH_INSTALL_BASE="$url/releases" FH_INSTALL_DIR="$scratch/$name/app" FH_BIN_DIR="$scratch/$name/bin" \
  sh >"$scratch/$name/output" 2>&1 || true
installed_nothing "$name" || not_ok "a truncated installer installed something"
if grep -q 'Looking up' "$scratch/$name/output"; then not_ok "a truncated installer ran"; fi
ok "a truncated installer does nothing"

[ -z "$(ls -A "$scratch/tmp")" ] || not_ok "the installer left a temp folder behind"
ok "no installer temp folders are left"

printf '1..%d\n' "$passed"
printf 'test-install: all passed for fh %s on %s\n' "$version" "$platform"
