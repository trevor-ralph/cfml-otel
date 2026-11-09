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

## Scope notes

- cfml-otel never sends telemetry anywhere itself. Export is done by the OpenTelemetry javaagent,
  configured with the standard `OTEL_*` settings. Keep exporter endpoints and headers (API keys) in
  the environment, not in code.
- Span attributes, events and log records are exported as given. Don't put secrets or personal data
  in them; recorded exceptions include messages and stack traces.
