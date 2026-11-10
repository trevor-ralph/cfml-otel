#!/usr/bin/env bash
# Fetches the third-party pieces the integration tests need (not shipped in the module):
#   - ColdBox, for tests/coldbox: dev/coldbox/ (mounted at /opt/coldbox). Version and SHA-256 pinned; when
#     bumping COLDBOX_VERSION, set COLDBOX_SHA256 to the new zip's hash (Ortus publishes .md5 / .sha512).
#   - Microsoft's JDBC driver for SQL Server, for ACF's "Other" datasource: dev/jdbc/mssql-jdbc.jar
#     (mounted into ACF's server lib folder). Verified against Maven Central's SHA-1, like build.sh.
# Runs on the host (bash + curl) or in the build container (`docker compose run --rm build`).
set -euo pipefail

COLDBOX_VERSION="${COLDBOX_VERSION:-8.3.0}"
COLDBOX_SHA256="${COLDBOX_SHA256:-302a45e278f2cc9b11aea051406e2bc1989d83fef684e3cfdb3fac61d1415573}"
MSSQL_JDBC_VERSION="${MSSQL_JDBC_VERSION:-13.6.2.jre11}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

unpack() { # <zip> <dest dir>: unzip where available, else the JDK's jar tool (the Maven image has no unzip)
  if command -v unzip >/dev/null; then
    unzip -q "$1" -d "$2"
  else
    local zip; zip="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
    (cd "$2" && jar xf "$zip")
  fi
}

dest="$ROOT/dev/coldbox"
if [[ -f "$dest/.version" && "$(cat "$dest/.version")" == "$COLDBOX_VERSION" ]]; then
  echo "ColdBox $COLDBOX_VERSION already in dev/coldbox"
else
  url="https://downloads.ortussolutions.com/ortussolutions/coldbox/$COLDBOX_VERSION/coldbox-$COLDBOX_VERSION.zip"
  echo "fetching $url"
  curl -fsSL "$url" -o "$tmp/coldbox.zip"
  got="$(sha256sum "$tmp/coldbox.zip" | cut -c1-64)"
  [[ "$got" == "$COLDBOX_SHA256" ]] || { echo "SHA-256 mismatch for $url: got $got" >&2; exit 1; }
  # empty it rather than delete it: running engine containers bind-mount this folder
  mkdir -p "$dest"
  find "$dest" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  unpack "$tmp/coldbox.zip" "$dest"
  [[ -f "$dest/system/Bootstrap.cfc" ]] || { echo "unexpected zip layout: no system/Bootstrap.cfc" >&2; exit 1; }
  echo "$COLDBOX_VERSION" > "$dest/.version"
  echo "ColdBox $COLDBOX_VERSION -> dev/coldbox"
fi

# --- Microsoft JDBC driver for SQL Server: ACF's "Other" datasource (README "Database queries") -----------
dest="$ROOT/dev/jdbc"
mkdir -p "$dest"
if [[ -f "$dest/.version" && "$(cat "$dest/.version")" == "$MSSQL_JDBC_VERSION" && -f "$dest/mssql-jdbc.jar" ]]; then
  echo "mssql-jdbc $MSSQL_JDBC_VERSION already in dev/jdbc"
else
  url="https://repo1.maven.org/maven2/com/microsoft/sqlserver/mssql-jdbc/$MSSQL_JDBC_VERSION/mssql-jdbc-$MSSQL_JDBC_VERSION.jar"
  echo "fetching $url"
  curl -fsSL "$url" -o "$tmp/mssql-jdbc.jar"
  want="$(curl -fsSL "$url.sha1" | cut -c1-40)"
  got="$(sha1sum "$tmp/mssql-jdbc.jar" | cut -c1-40)"
  [[ "$want" == "$got" ]] || { echo "SHA-1 mismatch for $url" >&2; exit 1; }
  mv "$tmp/mssql-jdbc.jar" "$dest/mssql-jdbc.jar"
  echo "$MSSQL_JDBC_VERSION" > "$dest/.version"
  echo "mssql-jdbc $MSSQL_JDBC_VERSION -> dev/jdbc/mssql-jdbc.jar"
fi
