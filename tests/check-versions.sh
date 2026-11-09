#!/usr/bin/env bash
# The version lives in four places. Fails unless they all agree (and match the tag, if given).
# Usage: bash tests/check-versions.sh [v<version>]
set -euo pipefail
cd "$(dirname "$0")/.."

box="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' box.json | head -1)"
module="$(sed -n 's/.*this\.version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' ModuleConfig.cfc | head -1)"
pom="$(sed -n 's:.*<version>\(.*\)</version>.*:\1:p' java/pom.xml | head -1)"   # first <version> = the project's
bridge="$(sed -n 's/.*String VERSION[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' java/src/main/java/cfmlotel/bridge/OtelBridge.java | head -1)"

echo "box.json=$box ModuleConfig.cfc=$module pom.xml=$pom OtelBridge.VERSION=$bridge"
[[ -n "$box" ]] || { echo "could not read the version from box.json" >&2; exit 1; }
for v in "$module" "$pom" "$bridge"; do
  [[ "$v" == "$box" ]] || { echo "version mismatch: all four must equal box.json ($box)" >&2; exit 1; }
done
if [[ $# -gt 0 ]]; then
  [[ "$1" == "v$box" ]] || { echo "tag $1 does not match box.json version (v$box)" >&2; exit 1; }
fi
