# Changelog

All notable changes to cfml-otel. The release workflow publishes each version's section as its GitHub
release notes.

## [Unreleased]

### Added
- **Agent extension for ACF's built-in database drivers** (`lib/agent/cfml-otel-agent-extension.jar`, loaded with
  `-Dotel.javaagent.extensions=`). ACF's own drivers (`macromedia.jdbc.MacromediaDriver`: SQL Server, Oracle, DB2,
  MySQL, Sybase) use `jdbc:macromedia:` URLs, which the agent can't parse, so their queries were traced as
  `db.system=other_sql` with no host, port or database name. With the extension they are identified like any other
  driver (`mssql`, `server.address`, `server.port`, `db.name`; tested with SQL Server on ACF 2025 and 2023). New
  startup check `ACF_JDBC_EXTENSION` when it isn't loaded; `status().agentExtension`.
- **FusionReactor no longer stops the agent's database spans**, given
  `-Dfr.mixin.black.list=<cfml-otel>/lib/agent/fusionreactor-jdbc-mixin-blacklist.csv`. FusionReactor's JDBC
  mixins add its own interfaces to driver classes, which the agent can't resolve, so it left every statement class
  uninstrumented. The file keeps FusionReactor's mixins out of the JDBC driver packages; FusionReactor still records
  `cfquery` through its ColdFusion integration. New startup check `FUSIONREACTOR_JDBC_MIXINS` when FusionReactor is
  attached without it. Reproduced and verified on ACF 2023 with FusionReactor 2026.1.3.
- Lucee 8.0 support: integration-tested on Lucee 8.0.0 (Java 25, Tomcat 11) with the agent, without it, and
  on ARM. Nothing in cfml-otel needed changing. Lucee 8 still runs `cfhttp` on a worker thread (LDEV-6519),
  so keep the agent's HttpClient instrumentation off there as on Lucee 6 and 7.
- `otel.setRoute("orders.checkout")`: names the request by its route instead of its file, for front
  controllers (Fusebox, FW/1, `index.cfm?action=`) where every request was `GET /index.cfm`. With the agent it
  renames the agent's SERVER span and sets `http.route` on it and on the agent's `http.server.request.duration`
  metric, through the agent's own route mechanism (`lib/` now ships OpenTelemetry's
  `opentelemetry-instrumentation-api`, which must be loaded by the same class loader as `opentelemetry-api`;
  `setRoute()` detects when it isn't and logs where each came from). The ColdBox module calls it for you with
  the matched route pattern or the event name (`setRoute` setting, on by default).
- Bridge-only install for servers that already have `opentelemetry-api` on their classpath: load only the bridge
  jar. Supported from API 1.38.0; CI compiles the bridge against it and runs the full suite on ACF 2023 with
  API 1.38.0 in `cfusion/lib`.
- Startup checks: `DUPLICATE_OTEL_API` (the API is on the classpath more than once), `SERVER_OTEL_API` (info:
  running on the server's API), `OTEL_API_TOO_OLD`, and `OTEL_ENV_NOT_INHERITED` (Linux: `OTEL_*` variables set
  for the container but not in the JVM, as when ACF is started through `sudo`). `status()` adds `apiPath` and
  `bundledApiVersion`. `OTHER_APM_AGENT` now says that FusionReactor has been seen to stop the agent's database
  spans.
- One instance shared by several applications (server scope) works in applications without the module's
  mapping or jars (it used to fail on the first span or metric there), documented in the README.
- A sample Grafana dashboard ([docs/grafana](docs/grafana)).
- `otel.onAbort()`, to call from `Application.cfc` `onAbort()`. Requests ended by `cfabort` / `cflocation` skip
  `onRequestEnd()` on both engines, which left their scopes on the pooled thread and, with the SDK
  fallback, their SERVER span un-ended.

### Changed
- Span and metric objects are copied from templates instead of looked up by name on each call: much faster on
  Lucee, and independent of the calling application's mappings.
- ColdBox: SERVER spans are now named by route or event (`GET /api/users/:id/`, `GET main.index`) instead of
  `GET /index.cfm`. Set `setRoute: false` to keep the old names.

### Documented
- FusionReactor alongside the agent: why the agent's database spans disappeared and the fix (above), how to choose
  which of the two agents handles JDBC (per server, or per driver), and how to filter FusionReactor's internal log
  streams out of Loki.
- ACF started as a service: configure the agent with `-Dotel.*` in `jvm.config`, since `sudo` / init scripts
  drop the environment.
- `onError()` marks a request as failed even when its error page goes out as 200 (now tested).
- Tomcat JMX metrics and the experimental JVM metrics as recommended agent settings.

### Fixed
- SDK fallback: the request's SERVER span is parented on the inbound trace headers or nothing, never on a
  context an earlier request left current on the pooled thread.
- SDK fallback: a `service.name` set through `OTEL_RESOURCE_ATTRIBUTES` is no longer replaced by the
  application name.
- ColdBox: when an event throws and the app has an `exceptionHandler`, the SERVER span gets the status that
  handler chooses. A handler that answers a not-found error with a 404 no longer leaves the span marked
  ERROR (with the agent too); the exception is still recorded. Without a handler the status is 500.
- ColdBox with the SDK fallback: a `relocate()` no longer records the pre-redirect status (usually 200):
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
- The Lucee 7 engines now run Lucee 7.1.2 (was 7.0.6).
- Every agent engine loads the agent extension; on ACF the built-in SQL Server driver's spans must now be identified
  (system, host, port, database) instead of being an expected failure. JUnit tests run ACF's URLs through the
  agent's own JDBC URL parser.
- TestBox unit specs for the CFML side (`tests/specs`), run on every engine, including the ColdBox interceptor's
  branches with fakes (an app without an `exceptionHandler`, the automatic route); CodeQL code scanning for the
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
