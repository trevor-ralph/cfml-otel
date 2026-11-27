#!/usr/bin/env bash
# Publishes the bridge (java/) and the agent extension (agent-extension/) to Maven Central as
# io.github.trevor-ralph:cfml-otel-bridge and :cfml-otel-agent-extension. release.yml runs it in the build image
# (docker-compose.yml's `build` service) once the GitHub release exists. By hand, from dev/:
#   TAG=v<version> MAVEN_CENTRAL_USERNAME=... MAVEN_CENTRAL_PASSWORD=... MAVEN_GPG_KEY=... MAVEN_GPG_PASSPHRASE=... \
#     docker compose run --rm -e TAG -e MAVEN_CENTRAL_USERNAME -e MAVEN_CENTRAL_PASSWORD -e MAVEN_GPG_KEY \
#       -e MAVEN_GPG_PASSPHRASE --entrypoint bash build dev/maven-central-publish.sh
#
# The builds are reproducible (a fixed project.build.outputTimestamp in both poms), so each jar is rebuilt first and
# compared with the one in the release zip. Nothing is uploaded unless they're byte-identical: Maven Central gets
# the same jars as the checksummed, attested release.
#
# MAVEN_CENTRAL_DRY_RUN=1 does everything except the upload: it builds, signs and bundles
# (<module>/target/central-publishing/central-bundle.zip). Signing still needs a key; any throwaway key will do.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${TAG:?set TAG to the release tag, e.g. v0.3.3}"
version="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' box.json | head -1)"
[[ "$TAG" == "v$version" ]] || { echo "tag $TAG does not match box.json's version ($version)" >&2; exit 1; }
: "${MAVEN_GPG_KEY:?set MAVEN_GPG_KEY to the ASCII-armored private signing key}"
: "${MAVEN_GPG_PASSPHRASE:?set MAVEN_GPG_PASSPHRASE}"
dry="${MAVEN_CENTRAL_DRY_RUN:-}"
if [[ "$dry" != "1" ]]; then
  : "${MAVEN_CENTRAL_USERNAME:?set MAVEN_CENTRAL_USERNAME to the Central Portal user token's username}"
  : "${MAVEN_CENTRAL_PASSWORD:?set MAVEN_CENTRAL_PASSWORD to the Central Portal user token's password}"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# The release's jars, to compare against (MAVEN_CENTRAL_RELEASE_ZIP: a local zip instead, for testing)
if [[ -n "${MAVEN_CENTRAL_RELEASE_ZIP:-}" ]]; then
  cp "$MAVEN_CENTRAL_RELEASE_ZIP" "$tmp/release.zip"
else
  url="https://github.com/trevor-ralph/cfml-otel/releases/download/$TAG/cfml-otel-$version.zip"
  curl -fsSL --retry 6 --retry-max-time 300 "$url" -o "$tmp/release.zip"
fi
(cd "$tmp" && jar xf release.zip lib/)

# The Central Portal user token, read from the environment by Maven (never written to disk)
cat > "$tmp/settings.xml" <<'EOF'
<settings>
  <servers>
    <server>
      <id>central</id>
      <username>${env.MAVEN_CENTRAL_USERNAME}</username>
      <password>${env.MAVEN_CENTRAL_PASSWORD}</password>
    </server>
  </servers>
</settings>
EOF

skip_upload=false
[[ "$dry" == "1" ]] && skip_upload=true

publish() { # <module dir> <jar built in target/> <the same jar's path in the release zip>
  local module="$1" built="$2" released="$3"
  echo "== $module"
  (cd "$module" && mvn -B -q -C clean package -DskipTests)
  local want got
  want="$(sha256sum "$tmp/$released" | cut -c1-64)"
  got="$(sha256sum "$module/target/$built" | cut -c1-64)"
  if [[ "$want" != "$got" ]]; then
    echo "$module/target/$built ($got) differs from $released in the release zip ($want): not publishing" >&2
    exit 1
  fi
  echo "$built matches the release zip ($got)"
  (cd "$module" && mvn -B -C -s "$tmp/settings.xml" -P central deploy -DskipTests -Dcentral.skipUpload="$skip_upload")
}

publish java "cfml-otel-bridge-$version.jar" "lib/cfml-otel-bridge-$version.jar"
publish agent-extension "cfml-otel-agent-extension.jar" "lib/agent/cfml-otel-agent-extension.jar"

if [[ "$dry" == "1" ]]; then
  echo "dry run: bundles built, nothing uploaded"
else
  echo "published io.github.trevor-ralph:cfml-otel-bridge and :cfml-otel-agent-extension $version to Maven Central"
fi
