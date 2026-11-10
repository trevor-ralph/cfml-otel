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
# The agent version the startup check calls "tested" must be the one build.sh fetches for the tests
agent="$(sed -n 's/^AGENT_VERSION="\${AGENT_VERSION:-\([^}]*\)}".*/\1/p' build.sh | head -1)"
tested="$(sed -n 's/.*String TESTED_AGENT_VERSION[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' java/src/main/java/cfmlotel/bridge/OtelBridge.java | head -1)"
echo "build.sh AGENT_VERSION=$agent OtelBridge.TESTED_AGENT_VERSION=$tested"
[[ -n "$agent" && "$agent" == "$tested" ]] || { echo "OtelBridge.TESTED_AGENT_VERSION must equal build.sh's AGENT_VERSION" >&2; exit 1; }
if [[ $# -gt 0 ]]; then
  [[ "$1" == "v$box" ]] || { echo "tag $1 does not match box.json version (v$box)" >&2; exit 1; }
fi
