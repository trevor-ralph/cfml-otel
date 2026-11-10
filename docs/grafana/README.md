# Sample Grafana dashboard

[cfml-otel-overview.json](cfml-otel-overview.json) is a starting point for a CFML application traced with the
OpenTelemetry javaagent and cfml-otel, on Prometheus (or Mimir), Tempo and Loki. It isn't meant to be complete:
import it, then cut and extend it for your app.

| Section | What it shows | Source |
|---|---|---|
| Requests | Requests/s, 5xx share, p95 latency; rate and p95 by route; responses by status | the agent's `http.server.request.duration` |
| | Outbound calls by host | the agent's `http.client.request.duration` (ACF; on Lucee cfml-otel's helpers record spans only) |
| JVM | Heap by pool, GC time, CPU, threads | the agent's runtime metrics |
| Tomcat (collapsed) | Request threads, active sessions, errors | JMX: needs the setting below |
| Your metrics | Any metric the service records besides the standard ones (pick it in the "Your metric" variable) | `otel.counter()`, `histogram()`, `gauge()`, ... |
| Traces | Failed requests, requests over 1 s, database calls over 200 ms | Tempo (TraceQL) |
| Logs | Log volume by level; the logs, with links to their traces | Loki (`cflog` / `writeLog`, captured by the agent) |

## Import

Grafana: **Dashboards > New > Import**, upload the JSON, save. Then pick your Prometheus, Tempo and Loki data
sources and the service at the top; the dashboard has a variable for each, so no data-source IDs need editing.

## Settings that make it more useful

- **Request names.** Without them, "by route" shows the servlet mapping (`/*.cfm`) for every request. Call
  `otel.setRoute()` (README, "Request names"); the ColdBox module does it for you.
- **Tomcat metrics (JMX).** The agent reads Tomcat's MBeans once you opt in to its Tomcat metrics, which it still
  calls experimental; Lucee and ACF both run on Tomcat:

  ```
  -Dotel.jmx.metrics.experimental.included=tomcat.*
  ```

  (`-Dotel.jmx.target.system=tomcat` does the same on agent 2.x, but is deprecated and goes away in 3.0.)

- **More JVM detail.** `-Dotel.instrumentation.runtime-telemetry.emit-experimental-telemetry=true` adds the
  agent's experimental runtime metrics (buffer pools, memory pool details, CPU and more).

Put both in the JVM options next to `-javaagent` (ACF: `jvm.config`; Lucee: `setenv.sh`), or as
`OTEL_JMX_METRICS_EXPERIMENTAL_INCLUDED` / `OTEL_INSTRUMENTATION_RUNTIME_TELEMETRY_EMIT_EXPERIMENTAL_TELEMETRY` environment variables.

## Notes

- Metric names are as Prometheus stores the agent's OTLP metrics (`http.server.request.duration` becomes
  `http_server_request_duration_seconds_*`). If your backend translates names differently, adjust the queries.
- Database metrics: the agent records JDBC spans but, by default, no database client metrics, so the database
  panel searches traces instead.
- The logs panel leaves out FusionReactor's internal loggers (`com.intergral.*`); see the README section on
  FusionReactor.
- Checked against the dev stack in this repository (grafana/otel-lgtm) with the Lucee and ACF test engines.
