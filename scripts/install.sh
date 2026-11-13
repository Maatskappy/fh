#!/bin/sh
# Install fh from a prebuilt release.
#
#   curl -fsSL https://github.com/Maatskappy/fh/releases/latest/download/install.sh | sh
#
# Settings:
#   FH_VERSION       version to install (default: latest)
#   FH_INSTALL_BASE  release root (default: https://github.com/Maatskappy/fh/releases)
#   FH_INSTALL_DIR   where bundles are kept (default: ~/.fh/app)
#   FH_BIN_DIR       where the fh link goes (default: ~/.local/bin)
#
# Everything runs inside main, called on the last line, so a download that stops
# half way runs nothing.
set -eu

say() {
  printf '%s\n' "$*"
}

fail() {
  printf 'fh install: %s\n' "$*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

fetch() {
  if have curl; then
    curl -fsSL -o "$2" "$1"
  elif have wget; then
    wget -q -O "$2" "$1"
  else
    fail "curl or wget is needed to download fh."
  fi
}

sha256_of() {
  if have sha256sum; then
    sha256sum "$1" | awk '{print $1}'
  elif have shasum; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif have openssl; then
    openssl dgst -sha256 -r "$1" | awk '{print $1}'
  else
    fail "sha256sum, shasum or openssl is needed to check the download."
  fi
}

fh_tmp=
fh_stage=
fh_dest=
fh_previous=
fh_link_tmp=

cleanup() {
  [ -z "$fh_link_tmp" ] || rm -f -- "$fh_link_tmp"
  if [ -n "$fh_previous" ] && [ -d "$fh_previous" ]; then
    if [ -e "$fh_dest" ]; then rm -rf -- "$fh_previous"; else mv -- "$fh_previous" "$fh_dest"; fi
  fi
  [ -z "$fh_stage" ] || rm -rf -- "$fh_stage"
  [ -z "$fh_tmp" ] || rm -rf -- "$fh_tmp"
}

main() {
  base=${FH_INSTALL_BASE:-https://github.com/Maatskappy/fh/releases}
  base=${base%/}
  requested=${FH_VERSION:-latest}
  requested=${requested#v}
  if [ -z "${FH_INSTALL_DIR:-}" ] || [ -z "${FH_BIN_DIR:-}" ]; then
    [ -n "${HOME:-}" ] || fail "HOME is not set. Set FH_INSTALL_DIR and FH_BIN_DIR instead."
  fi
  install_dir=${FH_INSTALL_DIR:-$HOME/.fh/app}
  bin_dir=${FH_BIN_DIR:-$HOME/.local/bin}
  install_dir=${install_dir%/}
  bin_dir=${bin_dir%/}
  case "$install_dir" in /?*) ;; *) fail "FH_INSTALL_DIR must be an absolute path." ;; esac
  case "$bin_dir" in /?*) ;; *) fail "FH_BIN_DIR must be an absolute path." ;; esac
  case "$requested" in
    '' | .* | *[!0-9A-Za-z._-]*) fail "FH_VERSION '$requested' is not a version." ;;
  esac

  system=$(uname -s)
  machine=$(uname -m)
  case "$system-$machine" in
    Darwin-arm64 | Darwin-aarch64) os=macos; arch=aarch64 ;;
    *) fail "fh has no binary for $system-$machine. Available binaries: macOS arm64 (macOS 13 or newer). Build from source: https://github.com/Maatskappy/fh#build-from-source" ;;
  esac
  platform=$os-$arch

  for tool in tar awk mktemp; do
    have "$tool" || fail "$tool is needed to install fh."
  done

  link=$bin_dir/fh
  if [ -d "$link" ]; then
    fail "$link is a folder. Move it away, or set FH_BIN_DIR to another folder."
  fi
  if [ -e "$link" ] && [ ! -L "$link" ]; then
    fail "$link already exists and is not a link this installer made. Move it away, or set FH_BIN_DIR to another folder."
  fi

  trap cleanup EXIT
  trap 'exit 1' HUP INT TERM
  fh_tmp=$(mktemp -d "${TMPDIR:-/tmp}/fh-install.XXXXXX")

  say "Looking up fh $requested for $platform at $base"
  sums=$fh_tmp/SHA256SUMS
  if [ "$requested" = latest ]; then
    # Discover the version, then fetch both assets from its fixed tag. A new
    # release becoming latest during installation cannot mix versions.
    fetch "$base/latest/download/SHA256SUMS" "$sums" || fail "could not look up the latest fh release at $base"
    requested=$(awk -v suffix="-$platform.tar.gz" '
      substr($2, 1, 3) == "fh-" && substr($2, length($2) - length(suffix) + 1) == suffix {
        name = substr($2, 4, length($2) - length(suffix) - 3)
        print name
      }' "$sums")
    case "$requested" in
      '' | .* | *[!0-9A-Za-z._-]*) fail "the latest release does not name one fh version for $platform." ;;
    esac
  fi
  release=$base/download/v$requested
  fetch "$release/SHA256SUMS" "$sums" || fail "could not download $release/SHA256SUMS"

  # Each line is "<sha256>  <file name>".
  wanted=fh-$requested-$platform.tar.gz
  found=$(awk -v wanted="$wanted" '
    { name = $2; sub(/^\*/, "", name); if (name == wanted) print $1, name }
  ' "$sums")
  [ -n "$found" ] || fail "this release has no fh build for $platform."
  [ "$(printf '%s\n' "$found" | awk 'END { print NR }')" = 1 ] || fail "the release lists more than one fh build for $platform."
  expected=${found%% *}
  archive=${found#* }
  case "$expected" in
    *[!0-9a-f]*) fail "the checksum listed for $archive is not a SHA-256." ;;
  esac
  [ "${#expected}" = 64 ] || fail "the checksum listed for $archive is not a SHA-256."
  folder=${archive%.tar.gz}
  version=${folder#fh-}
  version=${version%"-$platform"}
  case "$version" in
    '' | .* | *[!0-9A-Za-z._-]*) fail "the release names a version this installer cannot use: '$version'." ;;
  esac

  fh_dest=$install_dir/$version
  say ""
  say "This will:"
  say "  download  $release/$archive"
  say "  check     its SHA-256 is $expected"
  say "  install   fh $version in $fh_dest"
  say "  link      $link -> $fh_dest/fh"
  say ""

  fetch "$release/$archive" "$fh_tmp/$archive" || fail "could not download $release/$archive"
  actual=$(sha256_of "$fh_tmp/$archive")
  if [ "$actual" != "$expected" ]; then
    fail "the download does not match its checksum (expected $expected, got $actual). Nothing was installed."
  fi
  say "Checksum matches."

  # ~/.fh is also fh's private profile. If this is the first thing to create it, create
  # it private; fh keeps it that way.
  parent=$(dirname -- "$install_dir")
  [ -d "$parent" ] || (umask 077 && mkdir -p -- "$parent")
  mkdir -p -- "$install_dir"

  # Unpack beside the final folder so the move into place is a rename.
  fh_stage=$(mktemp -d "$install_dir/.incoming.XXXXXX")
  tar -xzf "$fh_tmp/$archive" -C "$fh_stage" </dev/null
  if [ ! -f "$fh_stage/$folder/fh" ] || [ ! -x "$fh_stage/$folder/fh" ]; then
    fail "the archive does not contain $folder/fh. Nothing was installed."
  fi
  reported=$("$fh_stage/$folder/fh" --version </dev/null 2>/dev/null) || reported=
  [ "$reported" = "fh $version" ] || fail "the downloaded fh does not run on this machine. Nothing was installed."

  if [ -e "$fh_dest" ] || [ -L "$fh_dest" ]; then
    fh_previous=$install_dir/.previous.$$
    mv -- "$fh_dest" "$fh_previous"
  fi
  mv -- "$fh_stage/$folder" "$fh_dest"
  if [ -n "$fh_previous" ]; then
    rm -rf -- "$fh_previous"
    fh_previous=
  fi

  # A new link renamed over the old one: fh on PATH always points at a whole install.
  mkdir -p -- "$bin_dir"
  fh_link_tmp=$bin_dir/.fh-link.$$
  rm -f -- "$fh_link_tmp"
  ln -s "$fh_dest/fh" "$fh_link_tmp"
  mv -f -- "$fh_link_tmp" "$link"
  fh_link_tmp=

  say "Installed fh $version."
  case ":${PATH:-}:" in
    *":$bin_dir:"*) ;;
    *)
      say ""
      say "$bin_dir is not on your PATH. Add this line to your shell profile, then open a new terminal:"
      say "  export PATH=\"$bin_dir:\$PATH\""
      say ""
      ;;
  esac
  say "Run fh to get started."
}

main "$@"
