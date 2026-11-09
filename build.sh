#!/usr/bin/env bash
# Builds lib/ (OTel API jars + the cfml-otel bridge jar) and fetches the javaagent for dev/.
# Needs only bash, curl and Docker (the bridge compiles inside a Maven container).
set -euo pipefail

AGENT_VERSION="${AGENT_VERSION:-2.33.1}"
API_VERSION="${API_VERSION:-1.67.0}"   # keep <= the agent's bundled SDK version
MAVEN_IMAGE="${MAVEN_IMAGE:-maven:3.9.15-eclipse-temurin-21}"
MVN="https://repo1.maven.org/maven2"
ROOT="$(cd "$(dirname "$0")" && pwd)"

fetch() { # <maven path> <dest file>
  local url="$MVN/$1" dest="$2"
  [[ -f "$dest" ]] && return 0
  echo "fetching $url"
  curl -fsSL "$url" -o "$dest.part"
  local want got
  want="$(curl -fsSL "$url.sha1" | cut -c1-40)"
  got="$(sha1sum "$dest.part" | cut -c1-40)"
  [[ "$want" == "$got" ]] || { echo "SHA-1 mismatch for $url" >&2; rm -f "$dest.part"; exit 1; }
  mv "$dest.part" "$dest"
}

mkdir -p "$ROOT/lib" "$ROOT/dev/agent"

# 1. OTel API jars the module ships (app-scoped via this.javaSettings.loadPaths)
for a in api context common; do
  fetch "io/opentelemetry/opentelemetry-$a/$API_VERSION/opentelemetry-$a-$API_VERSION.jar" \
        "$ROOT/lib/opentelemetry-$a-$API_VERSION.jar"
done

# 2. Bridge jar (on Git Bash for Windows, stop MSYS rewriting container paths like /src)
HOST_JAVA="$ROOT/java"
command -v cygpath >/dev/null && HOST_JAVA="$(cygpath -w "$HOST_JAVA")"
MSYS_NO_PATHCONV=1 docker run --rm \
  -v "$HOST_JAVA:/src" -v cfml-otel-m2:/root/.m2 -w /src \
  "$MAVEN_IMAGE" mvn -B -q -Dotel.api.version="$API_VERSION" clean package
rm -f "$ROOT"/lib/cfml-otel-bridge-*.jar
cp "$ROOT"/java/target/cfml-otel-bridge-*.jar "$ROOT/lib/"

# 3. Javaagent for the dev stack (not shipped in the module)
fetch "io/opentelemetry/javaagent/opentelemetry-javaagent/$AGENT_VERSION/opentelemetry-javaagent-$AGENT_VERSION.jar" \
      "$ROOT/dev/agent/opentelemetry-javaagent.jar"

ls -l "$ROOT/lib"
