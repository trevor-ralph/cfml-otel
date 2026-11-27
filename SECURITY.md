# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub:
**[Report a vulnerability](https://github.com/trevor-ralph/cfml-otel/security/advisories/new)**
(Security tab → "Report a vulnerability"). Don't open a public issue for security problems.

Include the engine and version (Lucee / Adobe ColdFusion), the cfml-otel version, the OTel javaagent
version, and steps to reproduce. You should get an acknowledgement within a week.

## Supported versions

cfml-otel is pre-1.0: fixes land on the latest release only.

## Verifying releases

Every release zip is built by GitHub Actions from the tagged commit and ships with `SHA256SUMS` and a
signed build-provenance attestation. To check a download:

```bash
gh attestation verify cfml-otel-<version>.zip --repo trevor-ralph/cfml-otel
sha256sum -c SHA256SUMS
```

`box install cfml-otel` downloads that same zip: the ForgeBox entry points at the GitHub release.

The jars on Maven Central (`io.github.trevor-ralph:cfml-otel-bridge`, `:cfml-otel-agent-extension`, from 0.3.4) are
byte-identical to the ones in the zip: the release workflow rebuilds them reproducibly and refuses to upload anything
that differs. Each is signed with the maintainer's key, fingerprint
`BC54EE0066B636EACE8EB10B1F08410C13E37F1B` (on keyserver.ubuntu.com and keys.openpgp.org):

```bash
gpg --keyserver keyserver.ubuntu.com --recv-keys BC54EE0066B636EACE8EB10B1F08410C13E37F1B
gpg --verify cfml-otel-bridge-<version>.jar.asc cfml-otel-bridge-<version>.jar
```

Publishing to ForgeBox and Maven Central runs only for `v*` tags on main, from GitHub environments that hold the
credentials and require the maintainer's approval for each release.

## Scope notes

- cfml-otel only sends telemetry where the standard `OTEL_*` settings point. With the OpenTelemetry
  javaagent, the agent does the export. With the opt-in SDK fallback (`sdkFallback`), cfml-otel's own
  OTLP/HTTP exporter does, to the endpoint those settings name (by default `http://localhost:4318`, as
  with the agent). Keep exporter endpoints and headers (API keys) in the environment, not in code.
- Span attributes, events and log records are exported as given. Don't put secrets or personal data
  in them; recorded exceptions include messages and stack traces.
