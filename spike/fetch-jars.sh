#!/usr/bin/env bash
# Downloads the OTel javaagent and the OTel API jars from Maven Central,
# verifying each against Maven Central's published SHA-1.
set -euo pipefail

AGENT_VERSION="${AGENT_VERSION:-2.33.1}"
API_VERSION="${API_VERSION:-1.67.0}"   # SDK version agent 2.33.1 is built against
MVN="https://repo1.maven.org/maven2"
HERE="$(cd "$(dirname "$0")" && pwd)"

fetch() { # <maven path> <dest file>
  local url="$MVN/$1" dest="$2"
  if [[ ! -f "$dest" ]]; then
    echo "fetching $url"
    curl -fsSL "$url" -o "$dest.part"
    local want got
    want="$(curl -fsSL "$url.sha1" | cut -c1-40)"
    got="$(sha1sum "$dest.part" | cut -c1-40)"
    [[ "$want" == "$got" ]] || { echo "SHA-1 mismatch for $url" >&2; rm -f "$dest.part"; exit 1; }
    mv "$dest.part" "$dest"
  fi
}

mkdir -p "$HERE/agent" "$HERE/jars/otel"
fetch "io/opentelemetry/javaagent/opentelemetry-javaagent/$AGENT_VERSION/opentelemetry-javaagent-$AGENT_VERSION.jar" \
      "$HERE/agent/opentelemetry-javaagent.jar"
for a in api context common; do
  fetch "io/opentelemetry/opentelemetry-$a/$API_VERSION/opentelemetry-$a-$API_VERSION.jar" \
        "$HERE/jars/otel/opentelemetry-$a-$API_VERSION.jar"
done
ls -l "$HERE/agent" "$HERE/jars/otel"
