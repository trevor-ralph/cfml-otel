#!/usr/bin/env bash
# Fetches the third-party pieces the integration tests need (not shipped in the module):
#   - ColdBox, for tests/coldbox: dev/coldbox/ (mounted at /opt/coldbox). Version and SHA-256 pinned; when
#     bumping COLDBOX_VERSION, set COLDBOX_SHA256 to the new zip's hash (Ortus publishes .md5 / .sha512).
#   - The H2 JDBC driver, for the cfquery scenario: dev/jdbc/h2.jar (mounted into each engine's server lib
#     folder). Verified against Maven Central's SHA-1, like build.sh.
set -euo pipefail

COLDBOX_VERSION="${COLDBOX_VERSION:-8.3.0}"
COLDBOX_SHA256="${COLDBOX_SHA256:-302a45e278f2cc9b11aea051406e2bc1989d83fef684e3cfdb3fac61d1415573}"
H2_VERSION="${H2_VERSION:-2.5.252}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- ColdBox ------------------------------------------------------------------------------------
dest="$ROOT/dev/coldbox"
if [[ -f "$dest/.version" && "$(cat "$dest/.version")" == "$COLDBOX_VERSION" ]]; then
  echo "ColdBox $COLDBOX_VERSION already in dev/coldbox"
else
  url="https://downloads.ortussolutions.com/ortussolutions/coldbox/$COLDBOX_VERSION/coldbox-$COLDBOX_VERSION.zip"
  echo "fetching $url"
  curl -fsSL "$url" -o "$tmp/coldbox.zip"
  got="$(sha256sum "$tmp/coldbox.zip" | cut -c1-64)"
  [[ "$got" == "$COLDBOX_SHA256" ]] || { echo "SHA-256 mismatch for $url: got $got" >&2; exit 1; }
  rm -rf "$dest"
  mkdir -p "$dest"
  unzip -q "$tmp/coldbox.zip" -d "$dest"
  [[ -f "$dest/system/Bootstrap.cfc" ]] || { echo "unexpected zip layout: no system/Bootstrap.cfc" >&2; exit 1; }
  echo "$COLDBOX_VERSION" > "$dest/.version"
  echo "ColdBox $COLDBOX_VERSION -> dev/coldbox"
fi

# --- H2 JDBC driver ---------------------------------------------------------------------------------
dest="$ROOT/dev/jdbc"
mkdir -p "$dest"
if [[ -f "$dest/.version" && "$(cat "$dest/.version")" == "$H2_VERSION" && -f "$dest/h2.jar" ]]; then
  echo "H2 $H2_VERSION already in dev/jdbc"
else
  url="https://repo1.maven.org/maven2/com/h2database/h2/$H2_VERSION/h2-$H2_VERSION.jar"
  echo "fetching $url"
  curl -fsSL "$url" -o "$tmp/h2.jar"
  want="$(curl -fsSL "$url.sha1" | cut -c1-40)"
  got="$(sha1sum "$tmp/h2.jar" | cut -c1-40)"
  [[ "$want" == "$got" ]] || { echo "SHA-1 mismatch for $url" >&2; exit 1; }
  mv "$tmp/h2.jar" "$dest/h2.jar"
  echo "$H2_VERSION" > "$dest/.version"
  echo "H2 $H2_VERSION -> dev/jdbc/h2.jar"
fi
