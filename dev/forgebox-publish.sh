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

src="$PWD"
work="$(mktemp -d)"
cp box.json README.md CHANGELOG.md "$work/"
cd "$work"
box package set location="$url"

# ForgeBox shows README.md and CHANGELOG.md, but resolves their links to files in this repo (`](LICENSE)`,
# `](docs/grafana)`) against forgebox.io, where they lead nowhere. Point them at this tag on GitHub instead; the
# repository's copies keep relative links, which GitHub renders.
repo_url="https://github.com/trevor-ralph/cfml-otel"
for doc in README.md CHANGELOG.md; do
  grep -o '](\([^)]*\))' "$doc" | sed 's/^](\(.*\))$/\1/' | grep -Ev '^(https?:|mailto:|#)' | sort -u |
    while IFS= read -r link; do
      path="${link%%#*}"
      [[ -e "$src/$path" ]] || { echo "$doc links to $link, which isn't in the repository" >&2; exit 1; }
      kind=blob
      [[ -d "$src/$path" ]] && kind=tree
      esc="$(printf '%s' "$link" | sed 's/[]$.*^|[\\]/\\&/g')"   # [. would start a collating element
      sed -i "s|](${esc})|](${repo_url}/${kind}/${TAG}/${link})|g" "$doc"
      echo "$doc: $link -> ${repo_url}/${kind}/${TAG}/${link}"
    done
  left="$(grep -o '](\([^)]*\))' "$doc" | grep -Ev '\]\((https?:|mailto:|#)' || true)"
  [[ -z "$left" ]] || { echo "$doc still has links relative to the repository: $left" >&2; exit 1; }
done

if [[ "${FORGEBOX_DRY_RUN:-}" == "1" ]]; then
  echo "dry run: would publish cfml-otel $version to ForgeBox with this box.json:"
  cat box.json
  exit 0
fi

: "${FORGEBOX_API_TOKEN:?set FORGEBOX_API_TOKEN to your ForgeBox API token}"
box config set endpoints.forgebox.APIToken="$FORGEBOX_API_TOKEN" > /dev/null
box publish
