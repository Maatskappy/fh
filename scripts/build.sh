#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
zig build test-loops-native
python3 patches/fx/verify.py
stage=$(mktemp -d "$root/.dist-native-XXXXXX")
previous=
cleanup() {
  [ -z "$stage" ] || rm -rf -- "$stage"
  if [ -n "$previous" ] && [ -d "$previous/dist" ] && [ ! -e "$root/dist" ]; then mv -- "$previous/dist" "$root/dist"; fi
  [ -z "$previous" ] || rmdir -- "$previous" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
zig build bundle -Doptimize=ReleaseFast --prefix "$stage"
if [ -e "$root/dist" ]; then
  previous=$(mktemp -d "$root/.dist-previous-XXXXXX")
  mv -- "$root/dist" "$previous/dist"
fi
mv -- "$stage" "$root/dist"
stage=
[ -z "$previous" ] || rm -rf -- "$previous"
previous=
printf '%s\n' 'Built native fh in dist/. No Node runtime or npm dependencies.'
