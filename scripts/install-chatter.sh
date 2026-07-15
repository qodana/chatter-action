#!/usr/bin/env bash
# Download the pinned chatter binary and expose it as the step output `bin`.
# Hard pinning: only versions listed below are accepted; the sha256 is verified
# even when the download goes through an internal mirror (CHATTER_BASE_URL).
# CHATTER_BIN env overrides everything (local tests / pre-provisioned runners).
set -euo pipefail

log() { echo "chatter-action: $*" >&2; }
die() { echo "::error::chatter-action: $*"; exit 1; }

if [ -n "${CHATTER_BIN:-}" ] && [ -x "$CHATTER_BIN" ]; then
    log "using pre-provisioned binary $CHATTER_BIN"
    echo "bin=$CHATTER_BIN" >> "$GITHUB_OUTPUT"
    exit 0
fi

VERSION="${CHATTER_VERSION:-37-26e21a}"
BASE_URL="${CHATTER_BASE_URL:-https://download.jetbrains.com/qodana/chatter}"

case "$(uname -s)" in
    Darwin) os=macos ;;
    Linux)  os=linux ;;
    *) die "unsupported runner OS $(uname -s) (linux/macos only)" ;;
esac
case "$(uname -m)" in
    arm64|aarch64) arch=aarch64 ;;
    x86_64|amd64)  arch=x86_64 ;;
    *) die "unsupported runner arch $(uname -m)" ;;
esac

# --- pin table: release -> per-platform sha256 (update via PR to this action) ---
case "$VERSION-$os-$arch" in
    37-26e21a-linux-aarch64) sha=f70bb4ea387cbb38d2a59ca332ac8e589336a46d1132f1ca00fb1acbb2e6d2b0 ;;
    37-26e21a-linux-x86_64)  sha=d73c5e17e4013e4c3dbaa49cd2363933a4e235bfe4db8e961307e5935b034a99 ;;
    37-26e21a-macos-aarch64) sha=a75d6e13bb42bfc66d39fda3025bda5f70b3af49b79e23665a9976594d8b7294 ;;
    37-26e21a-macos-x86_64)  sha=f60c2a8deb2caca5c2cb4a7439a280561958d4b617cef6533f4e0ddcd48ec31c ;;
    *) die "chatter version '$VERSION' is not pinned for $os-$arch in this action release" ;;
esac

asset="chatter-$os-$arch.zip"
dest_dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/chatter-bin"
mkdir -p "$dest_dir"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

log "downloading $BASE_URL/$VERSION/$asset"
curl -fSL --retry 3 -o "$tmp/$asset" "$BASE_URL/$VERSION/$asset"

if command -v sha256sum >/dev/null 2>&1; then got=$(sha256sum "$tmp/$asset" | cut -d' ' -f1)
else got=$(shasum -a 256 "$tmp/$asset" | cut -d' ' -f1); fi
[ "$got" = "$sha" ] || die "sha256 mismatch for $asset: expected $sha, got $got"

unzip -oq "$tmp/$asset" -d "$tmp/x"
bin_path=$(find "$tmp/x" -type f -name 'chatter*' ! -name '*.sha256' | head -1)
[ -n "$bin_path" ] || bin_path=$(find "$tmp/x" -type f | head -1)
[ -n "$bin_path" ] || die "no binary inside $asset"
chmod +x "$bin_path"
mv "$bin_path" "$dest_dir/chatter"

log "installed $dest_dir/chatter (sha256 verified)"
echo "bin=$dest_dir/chatter" >> "$GITHUB_OUTPUT"
