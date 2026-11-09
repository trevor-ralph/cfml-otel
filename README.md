# cfml-otel

OpenTelemetry tracing, metrics and logs for **Lucee** and **Adobe ColdFusion**, built on top of the
[OpenTelemetry javaagent](https://github.com/open-telemetry/opentelemetry-java-instrumentation).

The agent auto-instruments the servlet container, JDBC (`cfquery`), outbound HTTP and logging libraries.
cfml-otel adds what the agent can't see from inside CFML: custom spans around your code, business
attributes, metrics, OTel logs correlated with the trace, and context propagation across `cfthread`,
`runAsync` and message boundaries. Everything goes to the agent's SDK and exporters, so you ship
OTLP to a Collector / Grafana Alloy and on to Tempo, Loki and Mimir/Prometheus (or any OTLP backend).

> Status: **0.1.0 scaffold**. Integration-tested (91 checks) on Lucee 7.0.6, Lucee 6.2.9,
> ACF 2025.0.14 and ACF 2023.0.26 with agent 2.33.1 — see [Testing](#testing). The ColdBox module wiring is not tested yet.

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
  touches an OTel object directly. (Background: [spike/FINDINGS.md](spike/FINDINGS.md).)
* Without the agent the API is a no-op, and so is every cfml-otel call. If the jars aren't on the classpath,
  cfml-otel disables itself and `otel.status().reason` says why.

## Install

### 1. Build `lib/`

```bash
./build.sh
```

This fetches `opentelemetry-api`, `-context` and `-common` (SHA-1 verified, from Maven Central) and
compiles the bridge in a Maven container. You need bash, curl and Docker, but no local JDK. It also downloads the
javaagent into `dev/agent/` for the dev stack.

**Version rule:** the API jars must be **≤ the agent's bundled SDK version**. Agent 2.33.1 bundles SDK 1.67.0,
which is the default. Override with `AGENT_VERSION=… API_VERSION=… ./build.sh`.

### 2. Attach the javaagent to the engine's JVM

| Engine | Where |
|---|---|
| Lucee (Tomcat) | `setenv.sh` / `CATALINA_OPTS`: `-javaagent:/path/opentelemetry-javaagent.jar` |
| Adobe CF | `cfusion/bin/jvm.config`, append to `java.args`: `-javaagent:/path/opentelemetry-javaagent.jar` |
| Docker | `JAVA_TOOL_OPTIONS=-javaagent:/otel/opentelemetry-javaagent.jar` (on ACF this also attaches to the setup JVM, which is harmless) |

Configure the agent with standard env vars: `OTEL_SERVICE_NAME`, `OTEL_EXPORTER_OTLP_ENDPOINT`, and so on.

**Lucee:** also set `OTEL_INSTRUMENTATION_APACHE_HTTPCLIENT_ENABLED=false`. See [Outbound HTTP](#outbound-http-cfhttp).

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
    function onRequestEnd() {
        application.otel.onRequestEnd();       // closes scopes the request leaked (important, see below)
    }
    function onError(exception, eventName) {
        application.otel.onError(exception);   // records the error on the agent's SERVER span
        // ... your normal error handling
    }
}
```

`this.javaSettings.loadPaths` is the one jar-loading method that works on both engines. Putting the
jars on the server classpath (Tomcat `lib/`, `cfusion/lib/`) also works. Lucee's OSGi bundle loading
does **not** work: the OTel manifests import `java.*` packages that Lucee's Felix framework doesn't export.

[tests/app/Application.cfc](tests/app/Application.cfc) is a working reference.

#### ColdBox (untested)

`box install` the module, then still add `modules/cfml-otel/lib/` to `this.javaSettings.loadPaths`.
ColdBox can't change the classpath for you. Configure it in `moduleSettings["cfml-otel"]`. Inject it with
`property name="otel" inject="OTel@cfmlotel";`. The bundled interceptor tags the SERVER span with
the event, records exceptions and calls `onRequestEnd()`.

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

- **ACF:** the agent instruments `cfhttp` correctly. Nothing to do.
- **Lucee:** Lucee runs `cfhttp` on a worker thread, so the agent's client spans start **orphan traces**. This
  happens on every call, not only ones with a `timeout` ([LDEV-6519](https://luceeserver.atlassian.net/browse/LDEV-6519)).
  The agent also overwrites any `traceparent` you set. The tested workaround:
  1. Set `OTEL_INSTRUMENTATION_APACHE_HTTPCLIENT_ENABLED=false`.
  2. Wrap outbound calls:

  ```cfml
  otel.span("GET inventory-service", function(s) {
      var h = otel.injectHeaders();
      cfhttp(url = target, result = "local.res") {
          for (var k in h) cfhttpparam(type = "header", name = k, value = h[k]);
      }
      s.setAttribute("http.response.status_code", val(local.res.statusCode));
  }, { "kind": "client" });
  ```

  Disabling that instrumentation also turns it off for Java libraries that use Apache HttpClient on the
  request thread. Usually that's the right trade, but check what your app uses.

### Metrics

```cfml
otel.counter("orders.placed", "Orders placed").add(1, { "channel": "web" });
otel.histogram("payment.latency", "Payment provider latency", "ms").record(elapsed);
otel.gauge("queue.depth").set(depth);
otel.upDownCounter("jobs.inflight").add(1);   // ... .add(-1)
```

Instruments are cached by name, so calling these inline is fine. The `valueType` argument is `long` (default for
counters) or `double` (default for histograms and gauges).

### Logs

`emitLog(severity, message, [attrs])` plus `logDebug` / `logInfo` / `logWarn` / `logError` send records
through the OTel Logs API. They carry the current `trace_id` / `span_id`, so in Grafana you can jump
between the Loki log line and the Tempo trace.

## Gotchas this library handles (and you should know about)

* **Leaked scopes poison pooled threads.** A span made current and never closed stays current on that
  Tomcat thread, and later, unrelated requests get attached to the old trace. cfml-otel tracks every scope
  it opens per thread. `onRequestEnd()` closes leftovers and writes a warning to the `cfml-otel` log.
  `span()` and `runInContext()` always close in `finally`.
* **ACF 2025 scope bug** (it doesn't reproduce on ACF 2023.0.26). On a `cfthread` or `runAsync` thread, when a CFC method calls a closure that
  was passed into it, and that closure calls a CFC method, the inner method's `variables` scope resolves
  to the *calling page's* variables. Only `this` stays correct. Unscoped calls to the component's own
  functions fail with "Variable X is undefined". cfml-otel keeps its state in `this.__state` to avoid this.
  **Your own CFCs can hit the same bug** if they're used like that from threads.
* **ACF won't let a CFC define methods named after built-in functions.** That's why the method names are
  `emitLog()`/`logInfo()` rather than `log()`, and `bindContext()` rather than `wrap()`.
* **CFML is case-insensitive.** `Span` and `span` are the same variable. This matters if you ever drop to
  Java interop.

## Testing

```bash
./build.sh
cd dev && docker compose up -d                   # Lucee 7, Lucee 6, ACF 2025, ACF 2023 + grafana/otel-lgtm
pwsh ../tests/run-integration.ps1                # or: -Engines lucee7,acf2023
```

[tests/app/scenarios.cfm](tests/app/scenarios.cfm) runs each scenario with a known `traceparent`. Then
[tests/run-integration.ps1](tests/run-integration.ps1) checks the results through Grafana's datasource proxy:
- Span parentage, status, events and attribute types in **Tempo**.
- Metrics in **Prometheus**.
- Trace-correlated logs in **Loki**.

It also leaks a scope deliberately and sends 40 more requests to make sure no pooled thread inherits it. Grafana is at
http://localhost:3000. The ACF containers accept Adobe's EULA (developer/trial edition) via `acceptEULA=YES`.

## Roadmap

* `otel.http()` helper that does the Lucee client-span + header injection for you.
* A PR for [LDEV-6519](https://luceeserver.atlassian.net/browse/LDEV-6519) (`ThreadContextPropagator` SPI)
  so Lucee `cfhttp` / `cfthread` propagate natively.
* SDK fallback when no agent is attached (bundle SDK + OTLP exporter + autoconfigure).
* Bridge `cflog`/`writeLog` output into OTel logs.
* Lucee extension (`.lex`) packaging with OSGi manifests that resolve under Felix.
* Older engines (Lucee 5.4, ACF 2021), ColdBox module tests, TestBox unit specs.
