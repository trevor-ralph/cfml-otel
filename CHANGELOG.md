# Changelog

All notable changes to cfml-otel. The release workflow publishes each version's section as its GitHub
release notes.

## [Unreleased]

### Added
- `otel.onAbort()`, to call from `Application.cfc` `onAbort()`. Requests ended by `cfabort` / `cflocation` skip
  `onRequestEnd()` on both engines, which left their scopes on the pooled thread and, with the SDK
  fallback, their SERVER span un-ended.

### Fixed
- SDK fallback: the request's SERVER span is parented on the inbound trace headers or nothing, never on a
  context an earlier request left current on the pooled thread.
- SDK fallback: a `service.name` set through `OTEL_RESOURCE_ATTRIBUTES` is no longer replaced by the
  application name.
- ColdBox with the SDK fallback: the SERVER span of a request whose event threw now carries
  `http.response.status_code` 500, and a `relocate()` no longer records the pre-redirect status (usually 200):
  it records the redirect's status once the app's `onAbort()` calls `otel.onAbort()`, and none before that.
- ColdBox: the module no longer has to be installed in a folder named `cfml-otel`.
- `httpSpan()` / `http()`: a failure while preparing the span (a URL with an unusable port, unusable options)
  no longer prevents the call itself; it runs untraced.
- SDK fallback: `url.query` on the SERVER span has signature and access-key parameters redacted, like
  `url.full` on CLIENT spans.
- SDK fallback: with `OTEL_SDK_DISABLED=true` the fallback reports `SDK_FALLBACK_FAILED` instead of claiming
  to run an SDK that exports nothing.
- SDK fallback: the OTLP sender keeps its connection alive between exports instead of reconnecting each time.

### Tests
- TestBox unit specs for the CFML side (`tests/specs`), run on every engine; CodeQL code scanning for the
  Java bridge, the Python test harness and the workflows.

### Removed
- The original classloading spike harness (`spike/`). Its findings are kept as
  [docs/classloading-spike.md](docs/classloading-spike.md); the integration suite covers all of them.

## [0.2.0] - 2026-11-10

### Added
- **Startup checks.** When the `OTel` instance is created it checks the JVM and reports problems once in the
  `cfml-otel` log and in `otel.status().warnings`, with stable codes: `NO_OTEL_AGENT`, `AGENT_NOT_BRIDGED`,
  `SDK_DISABLED`, `AGENT_OLDER_THAN_TESTED`, `OTHER_APM_AGENT` (FusionReactor, New Relic, Datadog,
  AppDynamics, Dynatrace, Elastic APM, SeeFusion, …), `LUCEE_HTTPCLIENT_INSTRUMENTATION`,
  `OTHER_IMPLEMENTATION`, `BRIDGE_NOT_LOADED`, `SDK_FALLBACK_FAILED`. `status()` also reports the agent and API
  versions, every JVM agent, and `mode` (`agent`, `sdk`, `other`, `noop`). Turn the log off with
  `logDiagnostics: false`.
- **`otel.http()` and `otel.httpSpan()`** for outbound HTTP: one CLIENT span per call on every engine, with
  the stable HTTP semantic conventions. Credentials and signature parameters are redacted from `url.full`;
  4xx/5xx and connection failures are errors. On ACF, where the agent already traces `cfhttp`, the helpers
  leave the span to it (`status().httpMode`); override with `cfhttpSpans`.
- **SDK fallback** (opt-in, `sdkFallback: true`, jars in `lib/sdk/`): without the javaagent, cfml-otel runs
  an OpenTelemetry SDK of its own, configured by the standard `OTEL_*` variables, one per application, and
  creates each request's SERVER span. New `onRequestStart()` and `shutdown()` for `Application.cfc`; the
  ColdBox module calls them itself. `serviceName` sets `service.name` per app.
- `closeLeakedScopes()`: scope cleanup for `cfthread` / `runAsync` bodies and mid-request use.
- `onError(exception, [statusCode])`.

### Fixed
- **ColdBox: app overrides in `moduleSettings["cfml-otel"]` were ignored**, the key 0.1.0's README showed.
  ColdBox merges overrides by the module's model namespace, `cfmlotel`. Both keys now work; the README shows
  `moduleSettings["cfmlotel"]`.

### Documented
- `cflog` / `writeLog` and LogBox's `CFAppender` need nothing from cfml-otel: the agent captures them, with
  the trace ID, on both engines. Also what else the agent ships (engine and Tomcat logs) and how to filter it.
- Running alongside other APM agents, beyond FusionReactor; tested with Datadog's agent as the OTel API.

### Tests
- Bridge unit tests (JUnit) for the startup checks, HTTP attributes and the OTLP sender.
- CI runs every engine without the agent too (SDK fallback), Lucee on ARM, and ACF with the agent's
  HttpClient instrumentation off.

## [0.1.0] - 2026-11-09

First release: spans, metrics, logs and context propagation for Lucee 6.2 / 7 and ACF 2023 / 2025 on top of
the OpenTelemetry javaagent, as a plain CFML component and a ColdBox module.
