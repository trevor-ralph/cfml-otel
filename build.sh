#!/usr/bin/env bash
# Builds lib/ (OTel API jars, opentelemetry-instrumentation-api, the cfml-otel bridge jar and, in lib/agent/, the
# javaagent extension) and fetches the javaagent for dev/.
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

# 1. OTel API jars the module ships (app-scoped via this.javaSettings.loadPaths).
#    opentelemetry-instrumentation-api (otel.setRoute(): the agent bridges its route updates) is released with the
#    agent and versioned like it. Drop jars left by other versions first, so lib/ never holds two.
INSTRUMENTATION_JAR="opentelemetry-instrumentation-api-$AGENT_VERSION.jar"
for f in "$ROOT"/lib/opentelemetry-*.jar; do
  if [[ -e "$f" && "$f" != *"-$API_VERSION.jar" && "$(basename "$f")" != "$INSTRUMENTATION_JAR" ]]; then
    echo "removing stale $(basename "$f")"
    rm -f "$f"
  fi
done
for a in api context common; do
  fetch "io/opentelemetry/opentelemetry-$a/$API_VERSION/opentelemetry-$a-$API_VERSION.jar" \
        "$ROOT/lib/opentelemetry-$a-$API_VERSION.jar"
done
fetch "io/opentelemetry/instrumentation/opentelemetry-instrumentation-api/$AGENT_VERSION/$INSTRUMENTATION_JAR" \
      "$ROOT/lib/$INSTRUMENTATION_JAR"

# 2. Bridge jar, plus the SDK fallback jars for lib/sdk/ (-C: fail on any checksum mismatch). Inside the
#    build container (`docker compose run --rm build`) Maven is on the PATH;
#    anywhere else it compiles in a throwaway Maven container, so the host never needs a JDK.
mvn_package() { # <project dir under $ROOT>
  if command -v mvn >/dev/null; then
    (cd "$ROOT/$1" && mvn -B -q -C -Dotel.api.version="$API_VERSION" -Dotel.instrumentation.version="$AGENT_VERSION" clean package)
  else
    # on Git Bash for Windows, stop MSYS rewriting container paths like /src
    local host_dir="$ROOT/$1"
    command -v cygpath >/dev/null && host_dir="$(cygpath -w "$host_dir")"
    MSYS_NO_PATHCONV=1 docker run --rm \
      -v "$host_dir:/src" -v cfml-otel-m2:/root/.m2 -w /src \
      "$MAVEN_IMAGE" mvn -B -q -C -Dotel.api.version="$API_VERSION" -Dotel.instrumentation.version="$AGENT_VERSION" clean package
  fi
}
mvn_package java
rm -f "$ROOT"/lib/cfml-otel-bridge-*.jar
cp "$ROOT"/java/target/cfml-otel-bridge-*.jar "$ROOT/lib/"
# SDK fallback jars (opt-in; apps add lib/sdk/ to their loadPaths only if they use sdkFallback)
rm -rf "$ROOT/lib/sdk"
mkdir -p "$ROOT/lib/sdk"
cp "$ROOT"/java/target/sdk/*.jar "$ROOT/lib/sdk/"

# 3. Javaagent extension (lib/agent/, loaded by the javaagent with -Dotel.javaagent.extensions=, never by an app):
#    identifies the database behind ACF's built-in macromedia JDBC drivers. Also next to the dev stack's agent.
mvn_package agent-extension
mkdir -p "$ROOT/lib/agent"
cp "$ROOT/agent-extension/target/cfml-otel-agent-extension.jar" "$ROOT/lib/agent/"
cp "$ROOT/agent-extension/target/cfml-otel-agent-extension.jar" "$ROOT/dev/agent/"

# 4. Javaagent for the dev stack (not shipped in the module). The jar name carries no version
#    (docker-compose mounts it by a fixed name), so a stamp file records which one is there.
AGENT_JAR="$ROOT/dev/agent/opentelemetry-javaagent.jar"
AGENT_STAMP="$ROOT/dev/agent/.version"
if [[ ! -f "$AGENT_STAMP" || "$(cat "$AGENT_STAMP")" != "$AGENT_VERSION" ]]; then
  rm -f "$AGENT_JAR"
fi
fetch "io/opentelemetry/javaagent/opentelemetry-javaagent/$AGENT_VERSION/opentelemetry-javaagent-$AGENT_VERSION.jar" \
      "$AGENT_JAR"
echo "$AGENT_VERSION" > "$AGENT_STAMP"

ls -l "$ROOT/lib"
