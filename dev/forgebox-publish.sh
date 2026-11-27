#!/usr/bin/env bash
# Publishes a release to ForgeBox. release.yml runs it (as the `forgebox` service in docker-compose.yml) once the
# GitHub release exists. By hand, from dev/: TAG=v<version> FORGEBOX_API_TOKEN=... docker compose run --rm forgebox
#
# ForgeBox gets this repository's box.json, README.md and CHANGELOG.md, with box.json's location set to the
# release's zip on GitHub. So `box install cfml-otel` downloads the very zip the release published: lib/ already
# built, listed in SHA256SUMS and covered by the build-provenance attestation. ForgeBox stores no copy of its own.
#
# FORGEBOX_DRY_RUN=1 checks everything and prints the box.json it would publish, without publishing.
set -euo pipefail

: "${TAG:?set TAG to the release tag, e.g. v0.3.3}"
version="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' box.json | head -1)"
[[ "$TAG" == "v$version" ]] || { echo "tag $TAG does not match box.json's version ($version)" >&2; exit 1; }

url="https://github.com/trevor-ralph/cfml-otel/releases/download/$TAG/cfml-otel-$version.zip"
curl -fsSL --retry 6 -o /dev/null -r 0-0 "$url" || { echo "the release zip isn't there: $url" >&2; exit 1; }

work="$(mktemp -d)"
cp box.json README.md CHANGELOG.md "$work/"
cd "$work"
box package set location="$url"

if [[ "${FORGEBOX_DRY_RUN:-}" == "1" ]]; then
  echo "dry run: would publish cfml-otel $version to ForgeBox with this box.json:"
  cat box.json
  exit 0
fi

: "${FORGEBOX_API_TOKEN:?set FORGEBOX_API_TOKEN to your ForgeBox API token}"
box config set endpoints.forgebox.APIToken="$FORGEBOX_API_TOKEN" > /dev/null
box publish
