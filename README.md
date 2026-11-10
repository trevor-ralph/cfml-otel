# cfml-otel

[![CI](https://github.com/trevor-ralph/cfml-otel/actions/workflows/ci.yml/badge.svg)](https://github.com/trevor-ralph/cfml-otel/actions/workflows/ci.yml)

OpenTelemetry tracing, metrics and logs for **Lucee** and **Adobe ColdFusion**, built on top of the
[OpenTelemetry javaagent](https://github.com/open-telemetry/opentelemetry-java-instrumentation).

The agent auto-instruments the servlet container, JDBC (`cfquery`), outbound HTTP and logging libraries.
cfml-otel adds what the agent can't see from inside CFML: custom spans around your code, business
attributes, metrics, OTel logs correlated with the trace, and context propagation across `cfthread`,
`runAsync` and message boundaries. Everything goes to the agent's SDK and exporters, so you ship
OTLP to a Collector / Grafana Alloy and on to Tempo, Loki and Mimir/Prometheus (or any OTLP backend).

> Status: **0.1.0 scaffold**. Integration-tested (plain CFML, ColdBox 8.3, SQL Server 2022) on Lucee 7.0.6,
> Lucee 6.2.9, ACF 2025.0.14 and ACF 2023.0.26 with agent 2.33.1 — see [Testing](#testing).

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
compiles the bridge with Maven, in a container, so no local JDK is needed. It also downloads the
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

#### ColdBox

Integration-tested with ColdBox 8.3 on all four engines ([tests/coldbox](tests/coldbox)).

`box install` the module, then still add `modules/cfml-otel/lib/` to `this.javaSettings.loadPaths`.
ColdBox can't change the classpath for you. Configure it in `moduleSettings["cfml-otel"]`. Inject it with
`property name="otel" inject="OTel@cfmlotel";`. The bundled interceptor:
- tags the SERVER span with `coldbox.event` / `coldbox.route` (turn off with `traceEvents: false`),
- records unhandled event exceptions on the SERVER span, with the CFML exception type,
- closes scopes an event left open, both after a normal request (`postProcess`) and after an exception
  (`onException`, since ColdBox skips `postProcess` then).

Your `Application.cfc` doesn't need to call `onRequestEnd()` / `onError()` itself.

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

### Database queries (cfquery)

Nothing to do: the agent's JDBC instrumentation traces `cfquery` / `queryExecute` on both engines, one CLIENT
span per statement, nested under whatever span is current (the SERVER span, or your own `span()`). Tested
on all four engines against SQL Server 2022, with each engine's own driver (Lucee's bundled Microsoft
driver, ACF's built-in "Microsoft SQL Server" driver):

- Span name: operation + table, e.g. `SELECT dbo.orders`.
- Attributes: `db.system`, `db.name`, `db.operation`, `db.sql.table`, `db.user`, `db.statement`,
  `server.address`, `server.port`.
- `db.statement` is sanitized: literal values are replaced with `?` (`VALUES (1, 'first')` becomes
  `VALUES (?, ?)`), so data from queries isn't recorded by default.

**ACF's built-in SQL Server driver loses the database identity.** It connects with
`jdbc:macromedia:sqlserver://...` URLs, which the agent's JDBC URL parser doesn't recognise. Queries are
still traced, with correct SQL, operation, table and nesting. But `db.system` is `other_sql` instead of
`mssql`, and `server.address`, `server.port` and `db.name` are missing. So Grafana's service graph and
database views can't tell which SQL Server a query went to. Lucee (Microsoft's driver,
`jdbc:sqlserver://`) is unaffected.

**Workaround (tested on ACF 2025 and 2023): use Microsoft's JDBC driver as an "Other" datasource.**
The agent then records `db.system=mssql`, `server.address`, `server.port` and `db.name` as on Lucee.
1. Put Microsoft's driver (`com.microsoft.sqlserver:mssql-jdbc`, the `.jre11` build) in
   `cfusion/lib/` and restart ColdFusion. ACF's `sqlserver` package doesn't include it; it only has
   Adobe's DataDirect driver.
2. Create the datasource with driver **Other**, class `com.microsoft.sqlserver.jdbc.SQLServerDriver`,
   and a URL like `jdbc:sqlserver://dbhost:1433;databaseName=mydb`. Or in `Application.cfc`:

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

Leaving the built-in driver as it is also fine: the SQL, timings and errors are all traced. The proper
fix belongs in the agent's
[JDBC URL parser](https://github.com/open-telemetry/opentelemetry-java-instrumentation): registering ACF's
`macromedia` prefix with the existing DataDirect parser.

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

### Logs

`emitLog(severity, message, [attrs])` plus `logDebug` / `logInfo` / `logWarn` / `logError` send records
through the OTel Logs API. They carry the current `trace_id` / `span_id`, so in Grafana you can jump
between the Loki log line and the Tempo trace.

## Gotchas this library handles (and you should know about)

* **Leaked scopes poison pooled threads.** A span made current and never closed stays current on that
  Tomcat thread, and later, unrelated requests get attached to the old trace. cfml-otel tracks every scope
  it opens per thread. `onRequestEnd()` closes leftovers on the request thread and writes a warning to the
  `cfml-otel` log. `span()` and `runInContext()` always close in `finally`, and closing a scope also closes
  anything opened after it that was left open. Scopes can only be closed by the thread that opened them, so
  on a `cfthread` / `runAsync` thread either stay inside `span()` / `bindContext()` / `runInContext()`, or
  call `otel.onRequestEnd()` at the end of the thread body if you use `makeCurrent()` directly.
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

## Running alongside FusionReactor

FusionReactor's agent (2025.2.0 and later) exports OTel itself, but it **does not register itself as the
global OTel SDK**. Code that calls `GlobalOpenTelemetry.get()` gets a no-op, and cfml-otel works through
`GlobalOpenTelemetry`. In practice:

| Agents on the JVM | cfml-otel |
|---|---|
| OTel javaagent | Works (the normal setup) |
| FusionReactor only | Every call is a no-op: no spans, metrics or logs. `otel.status()` reports `active: false` with `implementation` `...GlobalOpenTelemetry$ObfuscatedOpenTelemetry`. Harmless, but nothing is recorded. |
| FusionReactor + OTel javaagent | FusionReactor's own docs suggest this for custom OTel instrumentation ("point both at the same collector"). In a local test (FusionReactor 2026.1.3, **unlicensed**, ACF 2025) the full suite passed. Unlicensed, FusionReactor exported nothing, so this doesn't show how the two behave with FusionReactor fully active. |

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
docker compose run --rm build                                    # lib/, the javaagent, ColdBox (checksum-verified)
docker compose up -d lgtm mssql lucee7 lucee6 acf2025 acf2023    # Grafana LGTM, SQL Server 2022, the engines
docker compose run --rm tests                                    # pytest; e.g. ENGINES=lucee7,acf2023
```

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
- ACF's built-in SQL Server driver gives `db.system=other_sql`.

The runner waits for each engine itself, including ACF's first-boot restart, and writes `junit.xml` and
the raw scenario responses to `tests/results/`. Grafana is at http://localhost:3000.

Licences accepted by the dev stack, for development and testing only:
- **Adobe's ColdFusion EULA** (developer/trial edition): `acceptEULA=YES`.
- **Microsoft's SQL Server EULA** (Developer edition, not for production): `ACCEPT_EULA=Y`.

**Architecture:** the library is CPU-neutral (CFML + Java bytecode), and the Lucee, Grafana, Maven and
Python images support x86-64 and ARM. The ACF and SQL Server images are x86-64 only. On ARM, run the Lucee
engines without SQL Server: `MSSQL=0 docker compose run --rm --no-deps tests` with `ENGINES=lucee7,lucee6`.

[CI](.github/workflows/ci.yml) runs the suite on every push and pull request: one x86-64 job per engine,
and Lucee 7 and 6 on GitHub's ARM runners. Pushing a `v*` tag that matches `box.json`'s version runs
[release.yml](.github/workflows/release.yml), which builds and publishes the release zip.

## Roadmap

* `otel.http()` helper that does the Lucee client-span + header injection for you.
* A PR for [LDEV-6519](https://luceeserver.atlassian.net/browse/LDEV-6519) (`ThreadContextPropagator` SPI)
  so Lucee `cfhttp` / `cfthread` propagate natively.
* SDK fallback when no agent is attached (bundle SDK + OTLP exporter + autoconfigure).
* Bridge `cflog`/`writeLog` output into OTel logs.
* Lucee extension (`.lex`) packaging with OSGi manifests that resolve under Felix.
* Lucee 5.4 (maybe). ACF 2021 is out: Adobe's core support (and security patches) ended Nov 2025.
* TestBox unit specs (behaviour without the agent). ColdBox 7 coverage, if anyone needs it.

## License and acknowledgements

Apache-2.0, see [LICENSE](LICENSE) and [NOTICE](NOTICE). Release zips bundle the unmodified OpenTelemetry API
jars (Apache-2.0, © The OpenTelemetry Authors).

Prior art: [cbotel](https://github.com/coldbox-modules/cbotel) by Ortus Solutions, a ColdBox module for
W3C `traceparent` handling.

cfml-otel is an independent project. It is not affiliated with or endorsed by the OpenTelemetry project,
Adobe, the Lucee Association or Ortus Solutions.
