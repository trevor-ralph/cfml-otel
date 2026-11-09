# Classloading spike: CFML -> OTel API -> javaagent SDK

**Question:** if a CFML app calls the OpenTelemetry Java API while the OTel javaagent is attached,
do the calls reach the agent's SDK (same traces, same exporter), or silently no-op?

**Answer: yes, on Lucee 6.2, Lucee 7.0 and Adobe CF 2025**, provided the API jars are loaded through
an ordinary classloader. Two interop rules and one engine bug need designing around (below).

Run 2026-11-07. Agent 2.33.1, API 1.67.0 (the SDK version that agent is built on), Lucee 6.2.9.4 / 7.0.6.10
(Tomcat 11, JDK 21), ACF 2025.0.14, grafana/otel-lgtm 0.40.0.

## Matrix (clean run, freshly restarted engines)

`same` = observed trace ID equals the `traceparent` the test client sent; `other` = a different trace.

| engine / jar loading         | API visible | bridged to agent | `Span.current()` | custom span (direct calls) | custom span (via interface) | cfthread | cfthread + manual ctx | runAsync | cfhttp | cfhttp + timeout |
|------------------------------|---|---|---|---|---|---|---|---|---|---|
| Lucee 6/7, no jars           | no | – | – | – | – | – | – | – | other | other |
| Lucee 6/7, `javaSettings.loadPaths` | yes | **yes** | same | **ERR** (scope.close) | **same** | other | same | same | other | other |
| Lucee 6/7, `javaSettings.maven`     | yes | **yes** | same | **ERR** (scope.close) | **same** | other | same | same | other | other |
| Lucee 6/7, OSGi bundle (4-arg `createObject`) | **no** (bundle won't resolve) | – | – | – | – | – | – | – | other | other |
| Lucee 7, jars in Tomcat `lib/` | yes | **yes** | same | **ERR** (scope.close) | **same** | other | same | same | other | other |
| ACF 2025, no jars            | no | – | – | – | – | – | – | – | same | same |
| ACF 2025, `javaSettings.loadPaths` | yes | **yes** | same | same | same | other | same | same | same | same |
| ACF 2025, jars in `cfusion/lib` | yes | **yes** | same | same | same | other | same | same | same | same |

Tempo confirms `probe.custom.*` spans are children of the agent's `GET /*.cfm` SERVER span
in every "yes" row. `GlobalOpenTelemetry.get()` returns
`io.opentelemetry.javaagent.instrumentation.opentelemetryapi.v1_27.ApplicationOpenTelemetry127`
(the agent's bridge) in all of them. The agent instruments Lucee's `PhysicalClassLoader`, Tomcat's
`URLClassLoader`, ACF's `JavaDynamicClassLoader` and ACF's `BootstrapClassLoader` without complaint.

## Findings

1. **Ship the API jars, load them with `this.javaSettings.loadPaths`.** It is the one mechanism that
   works on both engines and keeps the jars app-scoped. Server-lib also works on both; Maven
   coordinates work on Lucee only. Pin `opentelemetry-api`/`-context`/`-common` to **≤ the agent's
   SDK version**: the bridge only knows API versions up to what the agent was built with.

2. **Lucee's OSGi route fails as-is.** The OTel bundles' manifests `Import-Package` `java.util.function`
   / `java.util.logging`; Lucee's Felix doesn't export `java.*` as wiring packages, so the bundle
   never resolves. Matters only for the future `.lex` — it would need repackaged manifests or plain
   (non-OSGi) jars. Not a blocker for the module.

3. **Never call methods on agent-bridge objects directly from CFML — dispatch through the public
   interface.** `span.makeCurrent()` returns a hidden lambda class (`AgentContextStorage$$Lambda`).
   CFML engines reflect on the *concrete* class, so `scope.close()` fails on Lucee:
   `NoClassDefFoundError` on 6.2, `IllegalAccessException` on 7.0. ACF happens to cope. Invoking
   `io.opentelemetry.context.Scope#close` (a `java.lang.reflect.Method` taken from the public
   interface) works everywhere. **Wrapper implication:** every call to an OTel object goes through
   one dispatch layer — either cached interface `Method`s, or (recommended) a tiny Java shim jar
   compiled against the API, so calls are `invokeinterface` with no CFML overload guessing
   (also removes `javacast` noise on ACF).

4. **A leaked Scope poisons pooled request threads across requests.** During the first run a failed
   `scope.close()` left a custom span current on Tomcat thread `http-nio-8888-exec-3`; ~90 s later
   an unrelated request on that thread reported `Span.current()` from the *old* trace and its custom
   spans were parented into it. **Wrapper implication:** track every scope it opens in a
   request-scoped stack and force-close leftovers in `onRequestEnd` / `onError` / `onAbort`;
   expose spans as `otel.span(name, fn)` so users rarely hold a Scope themselves.

5. **`cfthread` loses context on every engine; manual propagation works.** Capturing
   `Context.current()` on the request thread and `makeCurrent()`-ing it inside the thread keeps the
   trace. **Wrapper implication:** `otel.thread()` / `otel.wrap(fn)` helpers. `runAsync` already
   propagates on all engines (the agent's executor instrumentation covers it).

6. **Lucee `cfhttp` always starts a new root trace — even without `timeout`.** The agent does inject
   a `traceparent` (flags `03`, i.e. a fresh agent root), but Lucee runs the request on a worker
   thread so the client span has no parent. This is the LDEV-6519 problem, and it's broader than the
   forum thread suggests (not only timeout'd calls). ACF `cfhttp` nests correctly.
   **Options:** (a) wrapper `otel.http()` that opens the client span on the request thread and
   carries context into the call (needs testing whether the agent's Apache HttpClient
   instrumentation must be disabled on Lucee to stop it overwriting the header);
   (b) contribute the `ThreadContextPropagator` SPI to Lucee 7.1 (LDEV-6519, maintainers asked for a PR).

7. **ACF Docker quirk:** `JAVA_TOOL_OPTIONS` also attaches the agent to ACF's setup JVM at start-up.
   Harmless for the spike; in production put `-javaagent` in `jvm.config` `java.args` instead.

## Not covered yet

Metrics and logs (log4j appender / `cflog` trace correlation), `cfquery` JDBC spans (no DB in the
spike), Lucee 5 / ACF 2021–2023, ACF behind an IIS/Apache connector, behaviour when the app's API
jar is *newer* than the agent, and the no-agent SDK fallback path.

## Re-running

```bash
./fetch-jars.sh            # agent + API jars from Maven Central, SHA-1 verified
docker compose up -d       # Grafana at http://localhost:3000
pwsh ./run-probes.ps1      # matrix + Tempo span trees; raw JSON in results/
docker compose down
```
