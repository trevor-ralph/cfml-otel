#!/usr/bin/env bash
# The version lives in five places (box.json, ModuleConfig.cfc, both poms, OtelBridge). Fails unless they all agree (and match the tag, if given).
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
# opentelemetry-instrumentation-api (otel.setRoute()) is released with the agent: the pom compiles against that version
inst="$(sed -n 's:.*<otel.instrumentation.version>\(.*\)</otel.instrumentation.version>.*:\1:p' java/pom.xml | head -1)"
echo "pom.xml otel.instrumentation.version=$inst"
[[ "$inst" == "$agent" ]] || { echo "pom.xml otel.instrumentation.version must equal build.sh's AGENT_VERSION" >&2; exit 1; }
# The agent extension reaches the agent's internals by name: built against, and tested with, the same agent
ext="$(sed -n 's:.*<version>\(.*\)</version>.*:\1:p' agent-extension/pom.xml | head -1)"
ext_inst="$(sed -n 's:.*<otel.instrumentation.version>\(.*\)</otel.instrumentation.version>.*:\1:p' agent-extension/pom.xml | head -1)"
echo "agent-extension/pom.xml version=$ext otel.instrumentation.version=$ext_inst"
[[ "$ext" == "$box" && "$ext_inst" == "$agent" ]] || { echo "agent-extension/pom.xml must have box.json's version and build.sh's AGENT_VERSION" >&2; exit 1; }
# The API version the bridge reports as bundled must be the one build.sh ships in lib/ and the pom compiles against
api_build="$(sed -n 's/^API_VERSION="\${API_VERSION:-\([^}]*\)}".*/\1/p' build.sh | head -1)"
api_pom="$(sed -n 's:.*<otel.api.version>\(.*\)</otel.api.version>.*:\1:p' java/pom.xml | head -1)"
api_bridge="$(sed -n 's/.*String BUNDLED_API_VERSION[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' java/src/main/java/cfmlotel/bridge/OtelBridge.java | head -1)"
echo "build.sh API_VERSION=$api_build pom.xml otel.api.version=$api_pom OtelBridge.BUNDLED_API_VERSION=$api_bridge"
[[ -n "$api_build" && "$api_build" == "$api_pom" && "$api_build" == "$api_bridge" ]] || { echo "the bundled API version must agree in build.sh, pom.xml and OtelBridge" >&2; exit 1; }
# CHANGELOG.md needs a section for this version: the release workflow publishes it as the release notes
grep -qF "## [$box]" CHANGELOG.md || { echo "CHANGELOG.md has no \"## [$box]\" section" >&2; exit 1; }
if [[ $# -gt 0 ]]; then
  [[ "$1" == "v$box" ]] || { echo "tag $1 does not match box.json version (v$box)" >&2; exit 1; }
fi
