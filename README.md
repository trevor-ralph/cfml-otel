# cfml-otel

[![CI](https://github.com/trevor-ralph/cfml-otel/actions/workflows/ci.yml/badge.svg)](https://github.com/trevor-ralph/cfml-otel/actions/workflows/ci.yml)

OpenTelemetry tracing, metrics and logs for **Lucee** and **Adobe ColdFusion**, built on top of the
[OpenTelemetry javaagent](https://github.com/open-telemetry/opentelemetry-java-instrumentation).

The agent auto-instruments the servlet container, JDBC (`cfquery`), outbound HTTP and logging libraries.
cfml-otel adds what the agent can't see from inside CFML: custom spans around your code, business
attributes, metrics, OTel logs correlated with the trace, and context propagation across `cfthread`,
`runAsync` and message boundaries. Everything goes to the agent's SDK and exporters, so you ship
OTLP to a Collector / Grafana Alloy and on to Tempo, Loki and Mimir/Prometheus (or any OTLP backend).

> Status: **0.2.0**. Integration-tested (plain CFML, ColdBox 8.3, SQL Server 2022) on Lucee 8.0.0, Lucee 7.1.2,
> Lucee 6.2.9, ACF 2025.0.14 and ACF 2023.0.26, with agent 2.33.1 and without any agent
> ([SDK fallback](#without-the-javaagent-sdk-fallback)) — see [Testing](#testing).

> **On ACF, also load cfml-otel's agent extension** (`lib/agent/cfml-otel-agent-extension.jar`, see
> [step 2](#2-attach-the-javaagent-to-the-engines-jvm)). Without it the agent can't identify the database behind
> ACF's built-in drivers (`jdbc:macromedia:...`): queries are traced as `db.system=other_sql`, with no host, port
> or database name. **With FusionReactor attached**, also give FusionReactor the JDBC blacklist in `lib/agent/`, or
> the agent records no database spans at all; see
> [Running alongside other APM agents](#running-alongside-other-apm-agents).

```cfml
application.otel.span("checkout", function(span) {
    span.setAttributes({ "cart.items": arrayLen(cart.items), "customer.tier": customer.tier });
    application.otel.counter("checkout.started").add(1, { "tier": customer.tier });
    processPayment(cart);           // cfquery / cfhttp inside show up as children (agent spans)
    application.otel.logInfo("checkout complete", { "order.id": orderId });
});
```

## How it works

```
CFML  ──>  models/OTel.cfc  ──>  lib/cfml-otel-bridge.jar  ──>  OTel API (lib/)  ══agent bridge══>  agent SDK ──OTLP──> Collector/Alloy
```

* With the javaagent attached, the agent instruments the app's copy of the OTel API so
  `GlobalOpenTelemetry` resolves to the agent's SDK. Your spans nest under the agent's HTTP `SERVER` span.
* The agent hands back hidden / non-public bridge classes. CFML engines invoke Java methods by reflecting
  on the *concrete* class, which fails on Lucee (`NoClassDefFoundError` on 6.2, `IllegalAccessException`
  on 7.0). The small **bridge jar** calls everything through the public API interfaces, so CFML never
  touches an OTel object directly. (Background: [docs/classloading-spike.md](docs/classloading-spike.md).)
* Without the agent the API is a no-op, and so is every cfml-otel call, unless you turn on the opt-in
  [SDK fallback](#without-the-javaagent-sdk-fallback), which runs cfml-otel's own SDK. If the jars aren't on
  the classpath, cfml-otel disables itself. Either way, the [startup check](#startup-checks) says what it
  found in `otel.status()` and the `cfml-otel` log.

## Install

### 1. Get the module with `lib/` built

**Easiest:** download `cfml-otel-<version>.zip` from [Releases](https://github.com/trevor-ralph/cfml-otel/releases)
and unzip it where your app can map it. It contains the CFCs and the built jars. Each release also ships
`SHA256SUMS` and a signed build-provenance attestation:

```bash
gh attestation verify cfml-otel-<version>.zip --repo trevor-ralph/cfml-otel
```

**From source:**

```bash
docker compose -f dev/docker-compose.yml run --rm build    # any OS, only Docker needed
./build.sh                                                  # or directly on Linux / macOS / Git Bash
```

This fetches `opentelemetry-api`, `-context` and `-common` (SHA-1 verified, from Maven Central) and
compiles the bridge with Maven, in a container, so no local JDK is needed. Maven also puts the SDK
fallback's jars in `lib/sdk/` (checksum-verified). It also downloads the
javaagent into `dev/agent/` for the dev stack.

**Version rule:** the API jars must be **≤ the agent's bundled SDK version**. Agent 2.33.1 bundles SDK 1.67.0,
which is the default. Override with `AGENT_VERSION=… API_VERSION=… ./build.sh`.

#### Bridge-only install (the server already has OpenTelemetry jars)

Some servers already have `opentelemetry-api` on their classpath, usually because another library in
`cfusion/lib` (or Tomcat's `lib/`) depends on it; shops that manage that folder with a build tool can pull it in
without noticing. (None of ACF 2023's own packages does: their dependency manifest lists no OpenTelemetry jars.)
Adding `lib/`'s copies as well puts two API versions on one classpath. Instead, load **only the bridge jar** and
let it use the server's API:

```cfml
this.javaSettings = { loadPaths: [ otelRoot & "/lib/cfml-otel-bridge-<version>.jar" ], loadColdFusionClassPath: true };
```

For [`setRoute()`](#request-names-routes), also put `lib/opentelemetry-instrumentation-api-<agent version>.jar`
**in the same folder as the server's `opentelemetry-api`** (`cfusion/lib`), not in `loadPaths`: the agent only
takes routes when both are loaded by the same class loader. Shops that manage `cfusion/lib` with a build tool can
put the bridge jar there too instead of in `loadPaths`.

The server's API must be **1.38.0 or later** (the bridge is compiled against 1.67.0 and CI checks it against
1.38.0, which added the synchronous gauges), and no newer than the version the agent bundles.
[Startup checks](#startup-checks) tell you which API is in use and where it came from:
`SERVER_OTEL_API` (info) in this setup, `DUPLICATE_OTEL_API` if both copies are on the classpath, and
`OTEL_API_TOO_OLD` below 1.38.0. CI runs the full suite this way on ACF 2023 with API 1.38.0 in
`cfusion/lib` (the `acf2023-serverapi` engine). The SDK fallback still needs `lib/sdk/`, which goes with
`lib/`'s API version, so a bridge-only install is for use with the agent. `setRoute()` was checked this way on
API 1.38.0, 1.45.0 and 1.67.0 with the instrumentation jar beside the API; with it in `loadPaths` instead, it
fails on all three.

### 2. Attach the javaagent to the engine's JVM

| Engine | Where |
|---|---|
| Lucee (Tomcat) | `setenv.sh` / `CATALINA_OPTS`: `-javaagent:/path/opentelemetry-javaagent.jar` |
| Adobe CF | `cfusion/bin/jvm.config`, append to `java.args`: `-javaagent:/path/opentelemetry-javaagent.jar` |
| Docker | `JAVA_TOOL_OPTIONS=-javaagent:/otel/opentelemetry-javaagent.jar` (on ACF this also attaches to the setup JVM, which is harmless) |

Configure the agent with standard env vars: `OTEL_SERVICE_NAME`, `OTEL_EXPORTER_OTLP_ENDPOINT`, and so on.

**ACF started as a service:** prefer `-Dotel.*` system properties in `jvm.config` `java.args`, next to the
`-javaagent` option (`-Dotel.service.name=myapp -Dotel.exporter.otlp.endpoint=http://collector:4318`). Starting
ColdFusion through `sudo` or an init script (`coldfusion start`, `sysinit`) usually drops the environment, and
then the agent silently exports to its default, `http://localhost:4318`. On Linux the
[startup checks](#startup-checks) warn about this (`OTEL_ENV_NOT_INHERITED`) when the container's main process
has `OTEL_*` variables that the JVM doesn't.

**Lucee:** also set `OTEL_INSTRUMENTATION_APACHE_HTTPCLIENT_ENABLED=false`. See [Outbound HTTP](#outbound-http-cfhttp).

**Adobe CF:** also load cfml-otel's agent extension, next to the `-javaagent` option:
`-Dotel.javaagent.extensions=/path/to/cfml-otel/lib/agent/cfml-otel-agent-extension.jar` (or
`OTEL_JAVAAGENT_EXTENSIONS`). It's a plugin for the agent, not something the application loads, so it stays out
of `loadPaths`. It lets the agent identify the database behind ACF's built-in drivers; see
[Database queries](#database-queries-cfquery). It's built for, and tested with, the agent version this release
names (2.33.1). If a different agent changes the internals it relies on, queries are still traced but not identified,
and it logs a warning once.

**FusionReactor on the same server:** add
`-Dfr.mixin.black.list=/path/to/cfml-otel/lib/agent/fusionreactor-jdbc-mixin-blacklist.csv` too. See
[Running alongside other APM agents](#running-alongside-other-apm-agents).

### 3. Wire it into the application

#### Plain CFML apps

```cfml
component {   // Application.cfc
    this.name = "myapp";
    variables.otelRoot = expandPath("/path/to/cfml-otel");          // or an absolute path
    this.mappings["/cfmlotel"] = variables.otelRoot;
    this.javaSettings = { loadPaths: [ variables.otelRoot & "/lib/" ], loadColdFusionClassPath: true };

    function onApplicationStart() {
        application.otel = new cfmlotel.models.OTel({ "tracerName": "myapp" });
    }
    function onApplicationEnd(appScope) {
        appScope.otel.shutdown();              // flushes (only matters for the SDK fallback)
    }
    function onRequestStart() {
        application.otel.onRequestStart();     // no-op with the agent; starts the SERVER span in the SDK fallback
    }
    function onRequestEnd() {
        application.otel.onRequestEnd();       // closes scopes the request leaked (important, see below)
    }
    function onAbort() {
        application.otel.onAbort();            // the same after cfabort / cflocation, which skip onRequestEnd()
    }
    function onError(exception, eventName) {
        // set the status (cfheader statuscode=500) first, then:
        application.otel.onError(exception);   // records the error on the SERVER span
        // ... your normal error handling
    }
}
```

With the agent, only `onRequestEnd()`, `onAbort()` and `onError()` matter. `onRequestStart()` and `shutdown()`
cost nothing and keep the app ready for the SDK fallback.

`onError()` matters most if your error page goes out with status **200** (or any non-5xx status). The agent
judges a request by its status code, so on its own it records such a request as a success. `onError()` marks
the SERVER span as failed (status ERROR, with the exception recorded) whatever the HTTP status; tested on every
engine, with and without the agent.

`onAbort()` covers requests that end with `cfabort` or `cflocation`: the engine calls `onAbort()` for those, and
neither engine runs `onRequestEnd()` afterwards. Without it such a request's leaked scopes stay on the
pooled thread and, with the SDK fallback, its SERVER span is never ended.

`this.javaSettings.loadPaths` is the one jar-loading method that works on both engines. Putting the
jars on the server classpath (Tomcat `lib/`, `cfusion/lib/`) also works. Lucee's OSGi bundle loading
does **not** work: the OTel manifests import `java.*` packages that Lucee's Felix framework doesn't export.

[tests/app/Application.cfc](tests/app/Application.cfc) is a working reference.

#### One instance for several apps

Several applications in one JVM can share one instance, so they also share one tracer, one set of metric
instruments and, with the SDK fallback, one SDK and exporter. One application creates it in the server scope;
that one needs the `/cfmlotel` mapping and `lib/` in its loadPaths. The others need neither: they only call it.

```cfml
// the application that owns it
function onApplicationStart() {
    lock name="cfmlotel-shared" type="exclusive" timeout="10" {
        if (!structKeyExists(server, "otel")) server.otel = new cfmlotel.models.OTel({ "tracerName": "myapps" });
    }
}

// every application, the owner included
function onRequestStart() { if (structKeyExists(server, "otel")) server.otel.onRequestStart(); }
function onRequestEnd()   { if (structKeyExists(server, "otel")) server.otel.onRequestEnd(); }
function onAbort()        { if (structKeyExists(server, "otel")) server.otel.onAbort(); }
```

Things to know:
- Requests stay separate: each request's spans and leaked-scope cleanup are tracked per request and thread,
  not per instance.
- Everything reports under one `service.name` and tracer name. To tell the apps apart, add an attribute
  (`server.otel.currentSpan().setAttribute("app.name", this.name)` in `onRequestStart()`), or use one instance
  per app with the fallback's `serviceName` option.
- Don't call `shutdown()` from one application's `onApplicationEnd()`: with the SDK fallback that stops the
  SDK for all of them.
- The instance keeps the classes of the application that created it. If that application's loadPaths change,
  replace the instance (`structDelete(server, "otel")` and create it again).

Tested with a second application that has no mapping and no jars ([tests/shared](tests/shared)).

#### ColdBox

Integration-tested with ColdBox 8.3 on all four engines, with and without the agent ([tests/coldbox](tests/coldbox)).

`box install` the module, then still add `modules/cfml-otel/lib/` to `this.javaSettings.loadPaths`.
ColdBox can't change the classpath for you. Configure it in `config/Coldbox.cfc` under `moduleSettings["cfmlotel"]`
(the module's model namespace; `moduleSettings["cfml-otel"]`, which 0.1.0's README showed, also works). Inject it with
`property name="otel" inject="OTel@cfmlotel";`. The bundled interceptor:
- names each request by its matched route pattern (`GET /api/users/:id/`) or, when there is none, its event
  (`GET main.index`), on the SERVER span and the agent's `http.server.request.duration` (see
  [Request names](#request-names-routes); turn off with `setRoute: false`),
- tags the SERVER span with `coldbox.event` / `coldbox.route` (turn off with `traceEvents: false`),
- records unhandled event exceptions on the SERVER span, with the CFML exception type. If the app has an
  `exceptionHandler`, the span gets the status that handler sets (a 404 for a not-found error is recorded as
  404, not as a failed request); without one, ColdBox's 500,
- closes scopes an event left open, both after a normal request (`postProcess`) and after an exception
  (`onException`, since ColdBox skips `postProcess` then).

Your `Application.cfc` doesn't need to call `onRequestStart()` / `onRequestEnd()` / `onError()` itself.
`relocate()` is covered too: ColdBox announces `postProcess` before it redirects.

One addition is worth making to `Application.cfc`:

```cfml
function onAbort() {
    application.cbController.getWireBox().getInstance("OTel@cfmlotel").onAbort();
}
```

It does two things. A handler that calls `abort` directly bypasses the interceptor, and this cleans up after it.
And with the SDK fallback it is what gives a `relocate()` its real status code: the redirect's status isn't set
yet when `postProcess` runs, so once cfml-otel has seen this `onAbort()` being called it leaves the SERVER span
for it to end. Without it (and for the first redirect after a start) the span is ended at `postProcess` with
no `http.response.status_code`. With the agent, the agent records the status either way.

The module can live in a folder with any name (`modules/cfml-otel` is what `box install` creates).

### Without the javaagent (SDK fallback)

Where you can't attach the agent (shared or managed hosting, locked-down JVM options, a quick trial),
cfml-otel can run its own OpenTelemetry SDK. It's **opt-in**:

1. Add `lib/sdk/` to the loadPaths as well, next to `lib/` (11 jars, about 1.3 MB):
   `this.javaSettings = { loadPaths: [ otelRoot & "/lib/", otelRoot & "/lib/sdk/" ], ... }`.
2. Turn it on: `new cfmlotel.models.OTel({ "sdkFallback": true, ... })`, or `sdkFallback: true` in the
   ColdBox module settings.
3. Configure it with the same `OTEL_*` environment variables (or `-Dotel.*` system properties) the agent
   reads: `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES`, sampler, batch
   settings, and so on. It exports over OTLP `http/protobuf`, like the agent; gRPC isn't supported.
   `service.name`: the `serviceName` option if set (it wins over `OTEL_SERVICE_NAME`, so apps sharing a JVM
   can differ), else `OTEL_SERVICE_NAME`, else a `service.name` in `OTEL_RESOURCE_ATTRIBUTES`, else the
   application name.
4. Call `onRequestStart()` / `onRequestEnd()` / `onAbort()` / `onError()` and, in `onApplicationEnd()`, `shutdown()`, as in
   the example above. The ColdBox interceptor does the request calls for you.

The fallback only starts when no agent is attached and nothing else has registered OpenTelemetry, so the
same configuration is safe on servers that do have the agent. `otel.status().mode` says which is in use:
`agent`, `sdk`, `other` or `noop`.

**What you get:** a SERVER span per request, continuing incoming `traceparent` headers. It's named
`GET /path/page.cfm` and carries `http.request.method`, `http.route` (the template), `url.path`,
`url.query` (signature and access-key parameters redacted, as in `url.full` on CLIENT spans), `url.scheme`,
`server.address`/`port`, `client.address`, `user_agent.original` and
`http.response.status_code` (5xx = error). You also get all of cfml-otel's API (`span()`, metrics,
`log*()`, `httpSpan()` / `http()`, propagation) and leaked-scope cleanup.

**What you don't get**, compared with the agent: anything the agent instruments by itself.
- No `cfquery` / JDBC spans.
- No `cflog` capture; use `otel.log*()`.
- No JVM or runtime metrics.
- No automatic context on `runAsync` threads; use `bindContext()`, as for `cfthread`.
- Outbound `cfhttp` is traced only through `httpSpan()` / `http()`.

**Things to know:**
- Neither engine runs `onRequestEnd()` after `onError()`, so `onError()` ends the SERVER span. Set the
  response status before calling it, or pass it: `otel.onError(exception, 500)`. Otherwise the status is
  left off the span, which still records the error. If your own error handling runs afterwards and picks the
  status, call `otel.onError(exception, 0, false)` instead and `otel.onRequestEnd()` once the status is set:
  the span is then marked as failed only for a 5xx (the ColdBox module does this for `exceptionHandler`).
- Each `OTel` instance gets its own SDK, with its own `service.name`, even when applications share
  cfml-otel's classes (Lucee 6 loads identical jars through one class loader, even from separate folders).
  Call `shutdown()` before replacing an instance (an app reinit), or its exporter keeps running until the JVM
  stops. The ColdBox module does this on unload. A JVM shutdown hook flushes whatever is still running.
  `OTEL_SERVICE_NAME` applies to every app in the JVM; set the `serviceName` option per app instead.
- The OTLP sender is cfml-otel's own (`HttpURLConnection`-based). The SDK's standard senders need
  `java.net.http`, which Adobe ColdFusion's bundled Java runtime doesn't include, or the OkHttp and Kotlin jars.
- Tested on every engine (plain CFML and ColdBox), and Lucee 7 on ARM.

### Startup checks

When the `OTel` instance is created, cfml-otel checks what is attached to the JVM and whether anything will
actually be recorded. Every problem it finds is written once to the `cfml-otel` log (turn off with
`logDiagnostics: false`) and returned by `otel.status()`:

```cfml
writeDump(application.otel.status());
// active, agentBridged, agentPresent, agentVersion, apiVersion, apiPath, bundledApiVersion, testedAgentVersion,
// otherAgents (e.g. ["FusionReactor"]), jvmAgents, reason, warnings: [{ level, code, message }]
```

| Code | Meaning |
|---|---|
| `NO_OTEL_AGENT` | No OTel javaagent, no OTel SDK and no `sdkFallback`: every call is a no-op. Names any other APM agent it found. |
| `AGENT_NOT_BRIDGED` | The agent is attached but didn't bridge the app's `opentelemetry-api`: the API in `lib/` is newer than the agent supports, or the agent is disabled. |
| `SDK_DISABLED` | The agent bridged cfml-otel but its SDK is off (`otel.sdk.disabled=true`). |
| `AGENT_OLDER_THAN_TESTED` | Works, but the agent is older than the one this release is tested with. API features newer than the agent may do nothing. |
| `OTHER_APM_AGENT` | FusionReactor, New Relic, Datadog, AppDynamics, Dynatrace, Elastic APM, SeeFusion, … is attached alongside the OTel agent. See [Running alongside other APM agents](#running-alongside-other-apm-agents). |
| `FUSIONREACTOR_JDBC_MIXINS` | FusionReactor is attached without `-Dfr.mixin.black.list`, so the agent records no database spans. Names the file in `lib/agent/` to pass. |
| `ACF_JDBC_EXTENSION` | ACF with the agent, but without cfml-otel's agent extension: queries through ACF's built-in drivers are `db.system=other_sql`, with no server or database name. See [Database queries](#database-queries-cfquery). |
| `LUCEE_HTTPCLIENT_INSTRUMENTATION` | Lucee with the agent's HttpClient instrumentation on, which breaks `cfhttp` traces. See [Outbound HTTP](#outbound-http-cfhttp). |
| `OTHER_IMPLEMENTATION` (info) | The agent is attached, but something else registered OpenTelemetry, so telemetry goes there. |
| `BRIDGE_NOT_LOADED` | The jars in `lib/` aren't on the application's classpath. |
| `SDK_FALLBACK_FAILED` | `sdkFallback` is on but the SDK didn't start: `lib/sdk/` isn't on the classpath, the `OTEL_*` configuration is invalid, or `OTEL_SDK_DISABLED` is true. |
| `DUPLICATE_OTEL_API` | `opentelemetry-api` is on the classpath more than once (lists every copy and the one in use): load only the bridge jar. See [Bridge-only install](#bridge-only-install-the-server-already-has-opentelemetry-jars). |
| `SERVER_OTEL_API` (info) | cfml-otel runs on an `opentelemetry-api` from the server classpath, not `lib/`'s (a bridge-only install). |
| `OTEL_API_TOO_OLD` | That API is older than 1.38.0, the oldest the bridge supports. |
| `OTEL_ENV_NOT_INHERITED` | Linux: `OTEL_*` variables are set for the container's main process (PID 1) but not in the JVM's environment, typically because ACF was started through `sudo` or an init script. Says when telemetry is going to the default `localhost:4318`. |

The checks read JVM arguments, `JAVA_TOOL_OPTIONS` / `JDK_JAVA_OPTIONS`, system properties and `OTEL_*`
environment variables as the JVM itself has them, which is what the agent sees too. Settings made only in an
agent configuration file aren't seen, so a `LUCEE_HTTPCLIENT_INSTRUMENTATION` or `ACF_JDBC_EXTENSION` warning can be
a false alarm there. `otel.status().agentExtension` says whether the agent extension is configured.

## API

All methods are on the `OTel` instance. Spans and instruments are chainable.

### Spans

| Call | What it does |
|---|---|
| `span(name, fn, [options])` | Runs `fn(span)` inside a new current span and returns fn's result. Exceptions are recorded with status ERROR and rethrown. **Prefer this.** |
| `startSpan(name, [options])` | Starts a span that isn't current. You must call `.end()`. To nest children: `tok = s.makeCurrent()` … `otel.closeScope(tok)`. |
| `currentSpan()` | Usually the agent's SERVER span. Calling `.end()` on it is ignored. |
| `setAttributes(struct)` / `addEvent(name, [attrs])` / `recordException(e)` | Act on the current span. |
| `traceId()` / `spanId()` / `traceparent()` | IDs for the current context, e.g. to put in your own logs or error pages. |

`options`: `kind` (`internal` · `server` · `client` · `producer` · `consumer`), `attributes` (struct),
`parent` (a context from `captureContext()` / `extractContext()`, or `"root"` to start a new trace).

Span methods: `setAttribute(k, v)`, `setAttributes(struct)`, `addEvent(name, [attrs])`,
`recordException(e, [attrs])`, `setStatus("OK"|"ERROR"|"UNSET", [description])`, `updateName(name)`,
`makeCurrent()`, `context()`, `end()`, `getTraceId()`, `getSpanId()`, `isRecording()`.

**Attribute values:**
- Strings stay strings. CFML `"200"` is *not* coerced to a number.
- Numbers become longs when integral, otherwise doubles. Lucee stores every number as a double.
- Booleans are preserved, including ACF's `CFBoolean`.
- Arrays become homogeneous array attributes. Mixed arrays fall back to strings.
- Quote keys that contain dots: `{ "http.route": "/x" }`.

`recordException()` accepts a `catch` variable from either engine, a Java `Throwable`, or an `onError` exception.
`exception.type` is the CFML type (`cfcatch.type`, e.g. `Custom.Fail`), or the Java class name for plain Java exceptions.

### Request names (routes)

Behind a front controller (Fusebox, FW/1, any `index.cfm?action=` app), every request is `GET /index.cfm`, in
traces and in the agent's `http.server.request.duration` metric alike. Name the request by what it does:

```cfml
// e.g. in onRequestStart(), once the app knows the action
application.otel.setRoute("orders.checkout");
```

- **With the agent** this renames the agent's SERVER span (`GET orders.checkout`) and sets `http.route` on it
  **and** on `http.server.request.duration`, so request rates and latencies split by route. It goes through the
  agent's own route mechanism (OpenTelemetry's `opentelemetry-instrumentation-api`, which `lib/` ships and the
  agent bridges); tested on all four engines.
- **With the SDK fallback** it does the same on cfml-otel's SERVER span (the fallback records no HTTP metrics).
- Use a low-cardinality name that identifies the handler, never one with IDs or other per-request values.
- The first call in a request wins; a later call only replaces it with a longer route (the agent's rule). An
  application's call takes precedence over a framework's automatic route (the ColdBox module's).
- It returns whether the route reached the SERVER span. When it can't, it sets `http.route` on the current span
  instead and says why once in the `cfml-otel` log. The usual cause is a
  [bridge-only install](#bridge-only-install-the-server-already-has-opentelemetry-jars) with
  `opentelemetry-instrumentation-api` in `loadPaths` rather than beside the server's `opentelemetry-api`; the
  log line names both locations.

### Threads and async

`cfthread` **does not inherit trace context** on any engine. `runAsync` does, through the agent's executor
instrumentation, but wrapping it is harmless.

```cfml
var work = otel.bindContext(function() {          // captures the context NOW
    return otel.span("background-job", function(s) { ... });
});
thread name="t1" { work(); }                      // runs in the captured context

// or explicitly
var ctx = otel.captureContext();
thread name="t2" { application.otel.runInContext(ctx, function() { ... }); }
```

### Propagation

| Call | Use |
|---|---|
| `injectHeaders([struct])` | Merges `traceparent` / `tracestate` / `baggage` for the current context into a struct, for outbound calls or message headers. |
| `extractContext([headers])` | Builds a parent context from inbound headers: a queue message, a webhook, a non-HTTP entry point. Defaults to the request's headers, which the agent already handles. |

### Outbound HTTP (cfhttp)

Use `otel.http()` or `otel.httpSpan()` for outbound calls, and the same code produces one correct CLIENT
span per call on every engine:

```cfml
// cfhttp built for you: returns the normal cfhttp result
var res = otel.http("https://inventory.example.com/items/#id#", {
    method: "get", urlTemplate: "/items/{id}", timeout: 10,
    headers: { "Accept": "application/json" }
});

// or wrap your own cfhttp call (any attributes, files, multipart, ...)
var res = otel.httpSpan(target, function(headers, span) {
    cfhttp(url = target, method = "post", result = "local.res") {
        for (var k in headers) cfhttpparam(type = "header", name = k, value = headers[k]);
        cfhttpparam(type = "body", value = payload);
    }
    return local.res;                      // return the result so its status code is recorded
}, { method: "post", urlTemplate: "/orders" });
```

`http()` options: `method`, `headers`, `body`, `params` (array of `cfhttpparam` attribute structs),
`timeout`, and `cfhttp` (a struct of any other `cfhttp` attributes: `charset`, `redirect`, `username`,
`password`, `throwOnError`, `getAsBinary`, `clientCert`, `proxyServer`, …). Both take `urlTemplate` (a
low-cardinality route; the span is then named `GET /items/{id}`), `name` and `attributes`.

The span follows the stable HTTP semantic conventions:
- `http.request.method`, `server.address`, `server.port`, `url.full`, `http.response.status_code`,
  `url.template`.
- Credentials in the URL and signature query parameters (`sig`, `Signature`, `X-Goog-Signature`,
  `AWSAccessKeyId`) are redacted from `url.full`.
- 4xx/5xx responses, connection failures and exceptions set status ERROR and `error.type`.

**Why a helper, and what it does on each engine** (`otel.status().httpMode`):
- **Lucee (`span` mode):** Lucee runs `cfhttp` on a worker thread, so the agent's own HttpClient spans start
  **orphan traces** and overwrite the `traceparent` you send
  ([LDEV-6519](https://luceeserver.atlassian.net/browse/LDEV-6519); still the case on Lucee 8.0). Set
  `OTEL_INSTRUMENTATION_APACHE_HTTPCLIENT_ENABLED=false` (the [startup check](#startup-checks) warns if you
  don't); the helpers then create the CLIENT span and inject the headers themselves. Disabling that
  instrumentation also turns it off for Java libraries that use Apache HttpClient, so check what your app uses.
- **ACF (`agent` mode):** the agent already traces `cfhttp` correctly. Wrapping it in your own client span
  would trace every call twice, so the helpers only pass the headers through and leave the span to the agent.
  If you turn the agent's HttpClient instrumentation off on ACF too, they switch to `span` mode.
- Override with `cfhttpSpans: "always"` or `"never"` in the `OTel` config.

In `agent` mode the agent's span is used as it is: the `span` argument is a no-op, and `urlTemplate`, `name` and
`attributes` are ignored. Put attributes you need on every engine on an enclosing `otel.span()`.

Tested on all four engines: GET/POST with headers and body, 404, connection failure, and that the downstream
request continues the trace from the client span. CI also runs ACF 2025 with the agent's HttpClient
instrumentation off, which covers `span` mode on ACF.

### Database queries (cfquery)

Nothing to do on Lucee, and one JVM option on ACF: the agent's JDBC instrumentation traces `cfquery` /
`queryExecute` on both engines, one CLIENT span per statement, nested under whatever span is current (the SERVER
span, or your own `span()`). Tested on every engine against SQL Server 2022, with each engine's own driver
(Lucee's bundled Microsoft driver, ACF's built-in "Microsoft SQL Server" driver). Lucee 8 loads its bundled
drivers from Maven: a datasource defined in `Application.cfc` names the driver with
`"maven": "com.microsoft.sqlserver:mssql-jdbc:13.4.0.jre11"` (an older `"bundleName": "org.lucee.mssql"` no
longer loads there). It is traced the same way.

- Span name: operation + target, e.g. `SELECT dbo.orders`.
- Attributes: `db.system`, `db.name`, `db.operation`, `db.sql.table`, `db.user`, `db.statement`,
  `server.address`, `server.port`.
- `db.statement` is sanitized: literal values are replaced with `?` (`VALUES (1, 'first')` becomes
  `VALUES (?, ?)`), so data from queries isn't recorded by default.

**ACF's built-in drivers need cfml-otel's agent extension.** ACF's own drivers (Microsoft SQL Server, Oracle, DB2,
MySQL, Sybase: `macromedia.jdbc.MacromediaDriver`) are DataDirect drivers renamed to `jdbc:macromedia:<db>://`
URLs, a prefix the agent's JDBC URL parser doesn't recognise. On its own the agent still traces those queries, with
correct SQL, operation, table and nesting, but as `db.system=other_sql`, without `server.address`, `server.port` or
`db.name`. So Grafana's service graph and database views can't tell which database a query went to.

`lib/agent/cfml-otel-agent-extension.jar` fixes that. Load it into the agent with
`-Dotel.javaagent.extensions=/path/to/cfml-otel/lib/agent/cfml-otel-agent-extension.jar` (ACF: `jvm.config`
`java.args`, next to `-javaagent`). When a `macromedia` driver opens a connection, it reads the URL as the
`jdbc:datadirect:` URL it really is, using the agent's own DataDirect parser, and records the result for that
connection. ACF's SQL Server datasources then get `db.system=mssql`, `server.address`, `server.port` and `db.name`,
as on Lucee (tested on ACF 2025 and 2023). The same parser covers ACF's Oracle, MySQL and DB2 URLs (unit-tested for
Oracle and MySQL only; Sybase isn't one it knows). It changes nothing
else: no driver behaviour, no other datasources. Turn it off with
`-Dotel.instrumentation.cfml-otel-macromedia-jdbc.enabled=false`. Turning off the agent's JDBC instrumentation
turns it off as well. The [startup check](#startup-checks) `ACF_JDBC_EXTENSION` warns when it isn't loaded.

**Or use Microsoft's JDBC driver as an "Other" datasource** (tested on ACF 2025 and 2023), which the agent
identifies on its own: put `com.microsoft.sqlserver:mssql-jdbc` (the `.jre11` build) in `cfusion/lib/`, then create
the datasource with driver **Other**, class `com.microsoft.sqlserver.jdbc.SQLServerDriver` and a URL like
`jdbc:sqlserver://dbhost:1433;databaseName=mydb`:

```cfml
this.datasources["mydb"] = {
    driver: "other", class: "com.microsoft.sqlserver.jdbc.SQLServerDriver",
    url: "jdbc:sqlserver://dbhost:1433;databaseName=mydb", username: "...", password: "..."
};
```

It is a different driver, so check before switching production datasources:
- **Encryption:** since version 10, Microsoft's driver encrypts by default and validates the server
  certificate. Set `encrypt=false` or `trustServerCertificate=true` if your server isn't set up for that.
  The tests use `encrypt=false`.
- **Unicode:** it sends string parameters as Unicode (`sendStringParametersAsUnicode=true`) by default,
  which can affect index use on `VARCHAR` columns.
- **Behaviour:** ACF-specific advanced settings for the built-in driver don't apply. The tests only cover
  plain queries with `cfqueryparam`, not stored procedures or every SQL type.

Wrap a group of queries in `otel.span("orders.load", ...)` to see them as one unit of work.

### Metrics

```cfml
otel.counter("orders.placed", "Orders placed").add(1, { "channel": "web" });
otel.histogram("payment.latency", "Payment provider latency", "ms").record(elapsed);
otel.gauge("queue.depth").set(depth);
otel.upDownCounter("jobs.inflight").add(1);   // ... .add(-1)
```

Instruments are cached by name, so calling these inline is fine. The `valueType` argument is `long` (default for
counters) or `double` (default for histograms and gauges). A `long` instrument rounds fractional values to the
nearest whole number and warns once in the `cfml-otel` log; pass `valueType = "double"` to keep fractions.

**Worth turning on in the agent:** `-Dotel.jmx.metrics.experimental.included=tomcat.*` adds Tomcat's own metrics
(request threads, requests, errors and, on ACF, sessions) from JMX, on both Lucee and ACF (tested in CI), and
`-Dotel.instrumentation.runtime-telemetry.emit-experimental-telemetry=true` adds more JVM detail. (The older
`-Dotel.jmx.target.system=tomcat` still works on agent 2.x but is deprecated, and the agent says so at startup.)

**Dashboard:** [docs/grafana](docs/grafana) has a sample Grafana dashboard to start from: requests by route (RED),
outbound HTTP, JVM, Tomcat, your own metrics, traces and logs.

### Logs

**`cflog` and `writeLog` need nothing from cfml-otel.** Both engines log through log4j2, and the agent
captures log4j2 by default, so every `cflog` / `writeLog` reaches your logs backend with its severity and
the current `trace_id` / `span_id` (tested on all four engines). The logger name (`scope_name` in Loki) is
the log file: `coldfusion.user.<file>` on ACF, `server.cflog.<file>…` on Lucee. Lucee's `application` log
only records errors by default (`loggers.application.level` in `.CFConfig.json`), so lower writes to it
are dropped before the agent sees them. Lucee 6 prefixes the message with `<app name>->`.

`emitLog(severity, message, [attrs])` plus `logDebug` / `logInfo` / `logWarn` / `logError` send records
through the OTel Logs API directly. They also carry the current `trace_id` / `span_id`, and add structured
attributes, which `cflog` can't. Use one or the other for a given message, not both, or it appears twice.

**What else the agent ships.** It captures every log4j2 and `java.util.logging` record in the JVM, not
only yours: the engine's own logs (`coldfusion.server`, `coldfusion.http`, Lucee's `server.deploy`, …),
Tomcat's startup and connector logs, and cfml-otel's own `cfml-otel` warnings. To cut that down:
- `OTEL_INSTRUMENTATION_JAVA_UTIL_LOGGING_ENABLED=false` drops Tomcat's logs (`org.apache.*`) and keeps
  `cflog` (tested on Lucee 7).
- `OTEL_INSTRUMENTATION_LOG4J_APPENDER_ENABLED=false` turns off `cflog` capture along with the engine logs,
  leaving only `otel.log*()`.
- To keep `cflog` but drop specific engine loggers, filter in your Collector / Alloy, e.g. with the OTel
  Collector `filter` processor (tested with Collector 0.135 and 0.165: the two engine loggers are dropped,
  everything else passes):
  ```yaml
  processors:
    filter/engine-logs:
      logs:
        log_record:
          - 'IsMatch(instrumentation_scope.name, "^(coldfusion\\.server|coldfusion\\.user\\.cfpm-audit)$")'
  ```

**LogBox (ColdBox):** its file appenders write files directly, so the agent doesn't see them. LogBox's
`CFAppender` logs through `cflog`, so its output is captured, with the trace ID (tested on all four engines).

## Gotchas this library handles (and you should know about)

* **Leaked scopes poison pooled threads.** A span made current and never closed stays current on that
  Tomcat thread, and later, unrelated requests get attached to the old trace. cfml-otel tracks every scope
  it opens per thread. `onRequestEnd()` closes leftovers on the request thread and writes a warning to the
  `cfml-otel` log. `span()` and `runInContext()` always close in `finally`, and closing a scope also closes
  anything opened after it that was left open. Scopes can only be closed by the thread that opened them, so
  on a `cfthread` / `runAsync` thread either stay inside `span()` / `bindContext()` / `runInContext()`, or
  call `otel.closeLeakedScopes()` at the end of the thread body if you use `makeCurrent()` directly.
* **ACF 2025 scope bug** (it doesn't reproduce on ACF 2023.0.26). On a `cfthread` or `runAsync` thread, when a CFC method calls a closure that
  was passed into it, and that closure calls a CFC method, the inner method's `variables` scope resolves
  to the *calling page's* variables. Only `this` stays correct. Unscoped calls to the component's own
  functions fail with "Variable X is undefined". cfml-otel keeps its state in `this.__state` to avoid this.
  **Your own CFCs can hit the same bug** if they're used like that from threads.
* **ACF 2023 in containers on some Linux hosts.** Its bundled JDK 17 throws a `NullPointerException` in
  `CgroupV2Subsystem` ("anyController is null") on some cgroup v2 hosts, such as GitHub's Ubuntu runners, as
  soon as the agent reads CPU metrics. The agent fails, and ColdFusion never finishes starting. Add
  `-XX:-UseContainerSupport` to the JVM options. ACF 2025's newer JDK and Docker Desktop aren't affected.
* **ACF won't let a CFC define methods named after built-in functions.** That's why the method names are
  `emitLog()`/`logInfo()` rather than `log()`, and `bindContext()` rather than `wrap()`.
* **CFML is case-insensitive.** `Span` and `span` are the same variable. This matters if you ever drop to
  Java interop.

## Running alongside other APM agents

cfml-otel only reports through OpenTelemetry's global API, which the OTel javaagent provides. Other APM
agents (FusionReactor, New Relic, Datadog, AppDynamics, Dynatrace, …) generally don't register as that API by
default, so with one of them alone, cfml-otel is a no-op (`NO_OTEL_AGENT`). Running one alongside the OTel agent
(`OTHER_APM_AGENT`) starts, but two tracing agents can trace each request twice and overwrite each other's
`traceparent` header on outbound calls, and one can stop the other's instrumentation (FusionReactor and database
spans, below). Pick one tracing agent per environment where you can;
cfml-otel's calls are safe no-ops where the OTel agent isn't attached, so the same code runs everywhere.

Some agents can also act as the OpenTelemetry API themselves (for example Datadog with
`DD_TRACE_OTEL_ENABLED=true`). cfml-otel then reports through them: tested with Datadog's Java agent 1.67.1 alone
on Lucee 7, `otel.status()` showed `mode: "other"`, `active: true`, no warnings and `otherAgents: ["Datadog"]`,
and Datadog's tracer recorded cfml-otel's spans (seen in its debug log; not checked in a Datadog backend).
The other agents haven't been tried.

### FusionReactor

FusionReactor's agent (2025.2.0 and later) exports OTel itself, but it **does not register itself as the
global OTel SDK**. Code that calls `GlobalOpenTelemetry.get()` gets a no-op, and cfml-otel works through
`GlobalOpenTelemetry`. In practice:

| Agents on the JVM | cfml-otel |
|---|---|
| OTel javaagent | Works (the normal setup) |
| FusionReactor only | Every call is a no-op: no spans, metrics or logs. `otel.status()` reports `active: false` with `implementation` `...GlobalOpenTelemetry$ObfuscatedOpenTelemetry`. Harmless, but nothing is recorded. |
| FusionReactor + OTel javaagent | FusionReactor's own docs suggest this for custom OTel instrumentation ("point both at the same collector"). cfml-otel's own spans, metrics and logs work. **The agent's database (`cfquery` / JDBC) spans disappear unless FusionReactor gets the blacklist below** (`FUSIONREACTOR_JDBC_MIXINS`). |

**Database spans with FusionReactor.** FusionReactor adds code to the classes of every JDBC driver it knows
(SQL Server, ACF's `macromedia` drivers, MySQL, Oracle, PostgreSQL and others) through what it calls mixins. Each
mixin also adds one of FusionReactor's own interfaces (`java.mixins.fusionreactor.api.jdbc.*`) to the driver's
classes. The OTel agent can't look those interface types up, so it fails to instrument the driver's statement classes
(`NoSuchTypeException` in its debug log), and queries run without spans. This happens whatever order the two
`-javaagent` options are in, and with an unlicensed FusionReactor too.

The fix is FusionReactor's own `fr.mixin.black.list` setting: a file of package prefixes it leaves alone. cfml-otel
ships one listing the JDBC driver packages from FusionReactor's default mixin list:

```
-Dfr.mixin.black.list=/path/to/cfml-otel/lib/agent/fusionreactor-jdbc-mixin-blacklist.csv
```

With it, the agent traces every query again: SQL Server identification included, together with the agent extension
on ACF. FusionReactor still counts `cfquery` queries, their time and rows in its request data, through its ColdFusion
integration. What it gives up is its own driver-level instrumentation of those packages, for example JDBC calls that
Java libraries make outside `cfquery`. Tested on ACF 2023 with FusionReactor 2026.1.3 (unlicensed): the suite passes
as it does without FusionReactor, and FusionReactor's request log still shows each request's JDBC query count. Not in
CI, which has no FusionReactor.

**FusionReactor's own logs end up in Loki.** With both agents attached, the OTel agent's log capture also picks
up FusionReactor's internal log streams (`com.intergral.fusionreactor.logging.*`: heartbeat, gc, memory, classes
and so on), at the same rate as everything else. Drop them in the Collector, like the engine loggers in
[Logs](#logs):

```yaml
processors:
  filter/fusionreactor-logs:
    logs:
      log_record:
        - 'IsMatch(instrumentation_scope.name, "^com\\.intergral\\.")'
```

or leave them out at query time: ``{service_name="myapp"} | scope_name !~ `com\.intergral\..*` ``.

Not verified (needs a licensed FusionReactor):
- Whether each request is then traced twice, once by each agent, as separate traces.
- Whether both agents write `traceparent` on outbound HTTP (last writer wins, which can split traces).
- Overhead, and whether FusionReactor's own UI and profiler keep working with the OTel agent loaded.

Recommendations:
- Pick one agent per environment rather than stacking them. For example, the OTel javaagent + cfml-otel
  in production and FusionReactor on dev/test servers. cfml-otel calls are safe no-ops where the OTel
  agent isn't attached, so the same code runs everywhere.
- If you do run both, attach FusionReactor to the server JVM only. On ACF that's `jvm.config`, not
  `JAVA_TOOL_OPTIONS`, which ACF's setup tools also read: each would open FusionReactor's port and
  activate its licence. Point FusionReactor's OTel export at your collector explicitly
  (`-Dotel.exporter.otlp.endpoint=...`): with no endpoint it ships to FusionReactor's cloud (OpsPilot).
  Then check for duplicate traces before relying on it.

Sources: FusionReactor's [OTel migration guide](https://docs.fusionreactor.io/Getting-started/Tutorials/otel-migration/),
[OTel shipping](https://docs.fusionreactor.io/Getting-started/Tutorials/otel-shipping/) and
[OTel shipping config](https://docs.fusionreactor.io/Monitor-your-data/FR-Agent/Configuration/OTel-shipping-config/).

## Testing

Everything runs in containers; the host only needs Docker (Linux, macOS or Windows). From `dev/`:

```bash
docker compose run --rm build                                           # lib/, the javaagent, ColdBox, TestBox (checksum-verified)
docker compose up -d lgtm mssql lucee8 lucee7 lucee6 acf2025 acf2023    # Grafana LGTM, SQL Server 2022, the engines
docker compose run --rm tests                                           # pytest; e.g. ENGINES=lucee8,acf2023
```

Other engines are separate services: `lucee8-sdk`, `lucee7-sdk`, `lucee6-sdk`, `acf2025-sdk` and `acf2023-sdk` run without
the agent (SDK fallback), `acf2025-nohttp` runs ACF with the agent's HttpClient instrumentation off, and
`acf2023-serverapi` runs a bridge-only install on the oldest supported API (1.38.0 in `cfusion/lib`). Start
them with `docker compose up -d <names>`, then run e.g. `ENGINES=lucee7-sdk,acf2025-sdk MSSQL=0 docker compose run --rm tests`.

Two kinds of unit tests run too:
- JUnit tests for the bridge (startup checks, HTTP attributes, the OTLP sender) and the agent extension (ACF URLs
  through the agent's own JDBC URL parser), during the build.
- [TestBox](https://testbox.ortusbooks.com/) specs for the CFML side ([tests/specs](tests/specs)): no-op and
  broken-bridge behaviour, `span()` results and exceptions, scope ordering, propagation, the HTTP helpers,
  conversions. They run inside every engine container, with or without the agent, as part of the pytest run.
  TestBox 7.2.2 and its globber dependency are fetched SHA-256-pinned by `dev/fetch-test-deps.sh`.

On Linux you can also run `./build.sh` and `bash dev/fetch-test-deps.sh` directly (bash, curl, Docker).

[tests/app/scenarios.cfm](tests/app/scenarios.cfm) runs each scenario with a known `traceparent`. Then the
pytest runner in [tests/integration](tests/integration) checks the results through Grafana's datasource
proxy:
- Span parentage, status, events and attribute types in **Tempo**.
- Metrics in **Prometheus**.
- Trace-correlated logs in **Loki**.

It also leaks a scope deliberately and sends 40 more requests to make sure no pooled thread inherits it.
The ColdBox app in [tests/coldbox](tests/coldbox) loads this repo as an installed module and checks the
injection, the interceptor's span attributes, exception recording, and scope cleanup after both normal
and failing events. `cfquery` runs against the SQL Server container.

Known engine behaviour is reported as `xfail`, not hidden:
- `cfthread` without `bindContext()` loses the trace (every engine).
- Lucee 6, the LDEV-6519 control, gets the wrong `traceparent` on `cfhttp`.
- Without the agent: `runAsync` loses the trace, and `cflog` isn't captured.

The runner waits for each engine itself, including ACF's first-boot restart, and writes `junit.xml` and
the raw scenario responses to `tests/results/`. Grafana is at http://localhost:3000.

Licences accepted by the dev stack, for development and testing only:
- **Adobe's ColdFusion EULA** (developer/trial edition): `acceptEULA=YES`.
- **Microsoft's SQL Server EULA** (Developer edition, not for production): `ACCEPT_EULA=Y`.

**Architecture:** the library is CPU-neutral (CFML + Java bytecode), and the Lucee, Grafana, Maven and
Python images support x86-64 and ARM. The ACF and SQL Server images are x86-64 only. On ARM, run the Lucee
engines without SQL Server: `MSSQL=0 docker compose run --rm --no-deps tests` with `ENGINES=lucee8,lucee7,lucee6`.

[CI](.github/workflows/ci.yml) runs the suite on every push and pull request: one x86-64 job per engine (with the
agent, without it, ACF with the agent's HttpClient instrumentation off, and the bridge-only install), plus Lucee on
GitHub's ARM runners, and a job that compiles the bridge against the oldest supported OTel API (1.38.0).
Pushing a `v*` tag that matches `box.json`'s version runs [release.yml](.github/workflows/release.yml), which
builds and publishes the release zip, with the version's [CHANGELOG.md](CHANGELOG.md) section as the notes.
GitHub's CodeQL code scanning (default setup) analyses the Java bridge, the Python test harness and the
workflows; CodeQL has no CFML support.

## Roadmap

* A Hyper (ColdBox HTTP client) integration built on `httpSpan()`.
* A LogBox appender with structured attributes, and for the SDK fallback (LogBox's `CFAppender` already reaches OTel
  through `cflog` when the agent is attached).
* A PR for [LDEV-6519](https://luceeserver.atlassian.net/browse/LDEV-6519) (`ThreadContextPropagator` SPI)
  so Lucee `cfhttp` / `cfthread` propagate natively.
* Lucee extension (`.lex`) packaging with OSGi manifests that resolve under Felix.
* Lucee 5.4 (maybe). ACF 2021 is out: Adobe's core support (and security patches) ended Nov 2025.
* ColdBox 7 coverage, if anyone needs it.

## License and acknowledgements

Apache-2.0, see [LICENSE](LICENSE) and [NOTICE](NOTICE). Release zips bundle the unmodified OpenTelemetry API
jars (Apache-2.0, © The OpenTelemetry Authors).

Prior art: [cbotel](https://github.com/coldbox-modules/cbotel) by Ortus Solutions, a ColdBox module for
W3C `traceparent` handling.

cfml-otel is an independent project. It is not affiliated with or endorsed by the OpenTelemetry project,
Adobe, the Lucee Association or Ortus Solutions.
