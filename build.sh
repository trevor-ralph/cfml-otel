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

# 1. OTel API jars the module ships (app-scoped via this.javaSettings.loadPaths).
#    Drop jars left by a different API_VERSION first, so lib/ never holds two versions.
for f in "$ROOT"/lib/opentelemetry-*.jar; do
  if [[ -e "$f" && "$f" != *"-$API_VERSION.jar" ]]; then
    echo "removing stale $(basename "$f")"
    rm -f "$f"
  fi
done
for a in api context common; do
  fetch "io/opentelemetry/opentelemetry-$a/$API_VERSION/opentelemetry-$a-$API_VERSION.jar" \
        "$ROOT/lib/opentelemetry-$a-$API_VERSION.jar"
done

# 2. Bridge jar. Inside the build container (`docker compose run --rm build`) Maven is on the PATH;
#    anywhere else it compiles in a throwaway Maven container, so the host never needs a JDK.
if command -v mvn >/dev/null; then
  (cd "$ROOT/java" && mvn -B -q -Dotel.api.version="$API_VERSION" clean package)
else
  # on Git Bash for Windows, stop MSYS rewriting container paths like /src
  HOST_JAVA="$ROOT/java"
  command -v cygpath >/dev/null && HOST_JAVA="$(cygpath -w "$HOST_JAVA")"
  MSYS_NO_PATHCONV=1 docker run --rm \
    -v "$HOST_JAVA:/src" -v cfml-otel-m2:/root/.m2 -w /src \
    "$MAVEN_IMAGE" mvn -B -q -Dotel.api.version="$API_VERSION" clean package
fi
rm -f "$ROOT"/lib/cfml-otel-bridge-*.jar
cp "$ROOT"/java/target/cfml-otel-bridge-*.jar "$ROOT/lib/"

# 3. Javaagent for the dev stack (not shipped in the module). The jar name carries no version
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
