#!/usr/bin/env bash
# Fetches the third-party pieces the integration tests need (not shipped in the module):
#   - ColdBox, for tests/coldbox: dev/coldbox/ (mounted at /opt/coldbox). Version and SHA-256 pinned; when
#     bumping COLDBOX_VERSION, set COLDBOX_SHA256 to the new zip's hash (Ortus publishes .md5 / .sha512).
#   - TestBox (+ its globber dependency), for the CFML unit specs in tests/specs: dev/testbox/ (mounted at
#     /opt/testbox). Pinned by SHA-256 like ColdBox.
#   - Microsoft's JDBC driver for SQL Server, for ACF's "Other" datasource: dev/jdbc/mssql-jdbc.jar
#     (mounted into ACF's server lib folder). Verified against Maven Central's SHA-1, like build.sh.
# Runs on the host (bash + curl) or in the build container (`docker compose run --rm build`).
set -euo pipefail

COLDBOX_VERSION="${COLDBOX_VERSION:-8.3.0}"
COLDBOX_SHA256="${COLDBOX_SHA256:-302a45e278f2cc9b11aea051406e2bc1989d83fef684e3cfdb3fac61d1415573}"
TESTBOX_VERSION="${TESTBOX_VERSION:-7.2.2}"
TESTBOX_SHA256="${TESTBOX_SHA256:-bd801e3aa26a3739d6da0149fc3fa8cfbfdb02a2ffd0e5b7cb4b675932f92398}"
# TestBox 7 needs its "globber" dependency (CommandBox normally installs it): the source tag from GitHub
GLOBBER_VERSION="${GLOBBER_VERSION:-3.2.0}"
GLOBBER_SHA256="${GLOBBER_SHA256:-a2626684ac6d1a3c6835b394e763998f9af7d2bea78c43b1b6bc461840ce2917}"
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

# --- TestBox: the CFML unit specs in tests/specs ---------------------------------------------------------
dest="$ROOT/dev/testbox"
if [[ -f "$dest/.version" && "$(cat "$dest/.version")" == "$TESTBOX_VERSION" ]]; then
  echo "TestBox $TESTBOX_VERSION already in dev/testbox"
else
  url="https://downloads.ortussolutions.com/ortussolutions/testbox/$TESTBOX_VERSION/testbox-$TESTBOX_VERSION.zip"
  echo "fetching $url"
  curl -fsSL "$url" -o "$tmp/testbox.zip"
  got="$(sha256sum "$tmp/testbox.zip" | cut -c1-64)"
  [[ "$got" == "$TESTBOX_SHA256" ]] || { echo "SHA-256 mismatch for $url: got $got" >&2; exit 1; }
  mkdir -p "$dest"
  find "$dest" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  unpack "$tmp/testbox.zip" "$dest"
  [[ -f "$dest/system/TestBox.cfc" ]] || { echo "unexpected zip layout: no system/TestBox.cfc" >&2; exit 1; }
  echo "$TESTBOX_VERSION" > "$dest/.version"
  echo "TestBox $TESTBOX_VERSION -> dev/testbox"
fi

# TestBox's globber dependency, where CommandBox would put it (system/modules/globber)
dest="$ROOT/dev/testbox/system/modules/globber"
if [[ -f "$dest/.version" && "$(cat "$dest/.version")" == "$GLOBBER_VERSION" ]]; then
  echo "globber $GLOBBER_VERSION already in dev/testbox"
else
  url="https://github.com/Ortus-Solutions/globber/archive/refs/tags/v$GLOBBER_VERSION.zip"
  echo "fetching $url"
  curl -fsSL "$url" -o "$tmp/globber.zip"
  got="$(sha256sum "$tmp/globber.zip" | cut -c1-64)"
  [[ "$got" == "$GLOBBER_SHA256" ]] || { echo "SHA-256 mismatch for $url: got $got" >&2; exit 1; }
  mkdir -p "$tmp/globber" "$dest"
  unpack "$tmp/globber.zip" "$tmp/globber"
  find "$dest" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  cp -R "$tmp/globber/globber-$GLOBBER_VERSION/." "$dest/"
  [[ -f "$dest/models/PathPatternMatcher.cfc" ]] || { echo "unexpected zip layout: no models/PathPatternMatcher.cfc" >&2; exit 1; }
  echo "$GLOBBER_VERSION" > "$dest/.version"
  echo "globber $GLOBBER_VERSION -> dev/testbox/system/modules/globber"
fi
