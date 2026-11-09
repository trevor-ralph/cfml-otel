#!/usr/bin/env bash
# Fetches the ColdBox framework used by the ColdBox integration tests (tests/coldbox) into dev/coldbox/,
# which dev/docker-compose.yml mounts at /opt/coldbox. Version and SHA-256 are pinned; when bumping
# COLDBOX_VERSION, set COLDBOX_SHA256 to the new zip's hash (Ortus publishes .md5 / .sha512 next to it).
set -euo pipefail

COLDBOX_VERSION="${COLDBOX_VERSION:-8.3.0}"
COLDBOX_SHA256="${COLDBOX_SHA256:-302a45e278f2cc9b11aea051406e2bc1989d83fef684e3cfdb3fac61d1415573}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/dev/coldbox"
STAMP="$DEST/.version"

if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$COLDBOX_VERSION" ]]; then
  echo "ColdBox $COLDBOX_VERSION already in dev/coldbox"
  exit 0
fi

url="https://downloads.ortussolutions.com/ortussolutions/coldbox/$COLDBOX_VERSION/coldbox-$COLDBOX_VERSION.zip"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "fetching $url"
curl -fsSL "$url" -o "$tmp/coldbox.zip"
got="$(sha256sum "$tmp/coldbox.zip" | cut -c1-64)"
[[ "$got" == "$COLDBOX_SHA256" ]] || { echo "SHA-256 mismatch for $url: got $got" >&2; exit 1; }

rm -rf "$DEST"
mkdir -p "$DEST"
unzip -q "$tmp/coldbox.zip" -d "$DEST"
[[ -f "$DEST/system/Bootstrap.cfc" ]] || { echo "unexpected zip layout: no system/Bootstrap.cfc" >&2; exit 1; }
echo "$COLDBOX_VERSION" > "$STAMP"
echo "ColdBox $COLDBOX_VERSION -> dev/coldbox"
