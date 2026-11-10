"""Drives the test apps on each engine and reads the results back from Grafana's datasource proxy
(Tempo, Prometheus, Loki). Standard library only, so the runner image needs nothing but pytest.

Inside the compose network (the `tests` service) engines are reached by service name. With LOCAL=1 the
runner can also run on the host against the published ports.
"""
from __future__ import annotations

import base64
import json
import os
import secrets
import socket
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

LOCAL = os.environ.get("LOCAL") == "1"


@dataclass(frozen=True)
class Target:
    name: str
    host: str
    port: int          # port inside the compose network
    local_port: int    # port published on the host
    service: str       # OTEL_SERVICE_NAME
    sdk: bool = False  # no javaagent: cfml-otel's own SDK (sdkFallback)
    agent_http: bool = True  # the agent's Apache HttpClient instrumentation is on (OTEL_INSTRUMENTATION_APACHE_HTTPCLIENT_ENABLED)

    @property
    def base(self) -> str:
        return f"http://localhost:{self.local_port}" if LOCAL else f"http://{self.host}:{self.port}"

    @property
    def is_acf(self) -> bool:
        return self.name.startswith("acf")

    @property
    def db(self) -> bool:
        """cfquery checks need SQL Server (MSSQL=1) and the agent's JDBC instrumentation."""
        return MSSQL and not self.sdk

    @property
    def agent_traces_cfhttp(self) -> bool:
        """The agent makes cfhttp's CLIENT spans itself (ACF with its HttpClient instrumentation on): the
        helpers' "agent" mode. Everywhere else they make the span ("span" mode)."""
        return self.is_acf and not self.sdk and self.agent_http


TARGETS = {
    "lucee7": Target("lucee7", "lucee7", 8888, 8971, "cfml-otel-lucee7"),
    "lucee6": Target("lucee6", "lucee6", 8888, 8961, "cfml-otel-lucee6"),
    "acf2025": Target("acf2025", "acf2025", 8500, 8951, "cfml-otel-acf2025"),
    "acf2023": Target("acf2023", "acf2023", 8500, 8941, "cfml-otel-acf2023"),
    "lucee7-sdk": Target("lucee7-sdk", "lucee7-sdk", 8888, 8972, "cfml-otel-lucee7-sdk", sdk=True),
    "lucee6-sdk": Target("lucee6-sdk", "lucee6-sdk", 8888, 8962, "cfml-otel-lucee6-sdk", sdk=True),
    "acf2025-sdk": Target("acf2025-sdk", "acf2025-sdk", 8500, 8952, "cfml-otel-acf2025-sdk", sdk=True),
    "acf2023-sdk": Target("acf2023-sdk", "acf2023-sdk", 8500, 8942, "cfml-otel-acf2023-sdk", sdk=True),
    "acf2025-nohttp": Target("acf2025-nohttp", "acf2025-nohttp", 8500, 8953, "cfml-otel-acf2025-nohttp", agent_http=False),
}

GRAFANA = os.environ.get("GRAFANA_URL") or ("http://localhost:3000" if LOCAL else "http://lgtm:3000")
MSSQL = os.environ.get("MSSQL", "1") == "1"
EXPORT_WAIT = int(os.environ.get("EXPORT_WAIT_SECONDS", "15"))
READY_TIMEOUT = int(os.environ.get("READY_TIMEOUT_SECONDS", "900"))


def engines() -> list[Target]:
    names = [n.strip() for n in os.environ.get("ENGINES", "lucee7,lucee6,acf2025,acf2023").split(",") if n.strip()]
    unknown = [n for n in names if n not in TARGETS]
    if unknown:
        raise ValueError(f"unknown engine(s) {unknown}; known: {sorted(TARGETS)}")
    return [TARGETS[n] for n in names]


def hex_id(n_bytes: int) -> str:
    return secrets.token_hex(n_bytes)


# ---- HTTP -----------------------------------------------------------------------------------------

def http(url: str, headers: dict | None = None, timeout: int = 120) -> tuple[int, str]:
    req = urllib.request.Request(url, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def get_json(url: str, headers: dict | None = None, timeout: int = 120):
    status, body = http(url, headers, timeout)
    if status != 200:
        raise AssertionError(f"GET {url} -> HTTP {status}: {body[:500]}")
    return json.loads(body)


def traceparent(trace_id: str, parent_id: str) -> dict:
    return {"traceparent": f"00-{trace_id}-{parent_id}-01"}


# ---- Readiness ------------------------------------------------------------------------------------

def _ok(url: str) -> bool:
    try:
        return http(url, timeout=10)[0] == 200
    except (urllib.error.URLError, socket.timeout, ConnectionError, OSError):
        return False


def wait_until_ready(targets: list[Target]) -> None:
    """Grafana's datasources, then each engine. ACF restarts itself once during first-boot setup, so an
    engine only counts as ready after answering continuously for a while, not on its first 200."""
    def wait(label: str, url: str, stable: int) -> None:
        start, ok_since = time.monotonic(), None
        while True:
            now = time.monotonic()
            if _ok(url):
                ok_since = ok_since or now
                if now - ok_since >= stable:
                    print(f"{label} ready after {int(now - start)}s", flush=True)
                    return
            else:
                ok_since = None
            if now - start > READY_TIMEOUT:
                raise TimeoutError(f"{label} not ready after {READY_TIMEOUT}s ({url})")
            time.sleep(5)

    for ds in ("Tempo", "Prometheus", "Loki"):
        wait(f"grafana datasource {ds}", f"{GRAFANA}/api/datasources/name/{ds}", 0)
    for t in targets:
        wait(t.name, f"{t.base}/cfml-otel/tests/app/check.cfm", 60 if t.is_acf else 15)


# ---- Backends (through Grafana's datasource proxy) --------------------------------------------------

_ds_uids: dict[str, str] = {}


def ds_uid(name: str) -> str:
    if name not in _ds_uids:
        _ds_uids[name] = get_json(f"{GRAFANA}/api/datasources/name/{name}")["uid"]
    return _ds_uids[name]


def _b64_hex(s: str | None) -> str:
    return base64.b64decode(s).hex() if s else ""


def _attr_value(v: dict):
    if "stringValue" in v:
        return v["stringValue"]
    if "intValue" in v:
        return int(v["intValue"])
    if "doubleValue" in v:
        return float(v["doubleValue"])
    if "boolValue" in v:
        return bool(v["boolValue"])
    if "arrayValue" in v:
        return [_attr_value(x) for x in v["arrayValue"].get("values", [])]
    return None


def _attrs(items: list | None) -> dict:
    return {a["key"]: _attr_value(a.get("value", {})) for a in items or []}


@dataclass
class Span:
    name: str
    kind: str
    id: str
    parent: str
    status: str
    attrs: dict
    events: list[dict] = field(default_factory=list)   # [{"name":..., "attrs": {...}}]
    scope: str = ""                                     # instrumentation scope (tracer) name

    def event_attr(self, event: str, key: str) -> list:
        return [e["attrs"].get(key) for e in self.events if e["name"] == event]


_trace_cache: dict[str, list[Span]] = {}


def spans(trace_id: str) -> list[Span]:
    if trace_id not in _trace_cache:
        status, body = http(f"{GRAFANA}/api/datasources/proxy/uid/{ds_uid('Tempo')}/api/v2/traces/{trace_id}")
        out: list[Span] = []
        if status == 200:
            for rs in json.loads(body).get("trace", {}).get("resourceSpans", []):
                for ss in rs.get("scopeSpans", []):
                    for sp in ss.get("spans", []):
                        out.append(Span(
                            name=sp.get("name", ""), kind=sp.get("kind", ""),
                            id=_b64_hex(sp.get("spanId")), parent=_b64_hex(sp.get("parentSpanId")),
                            status=sp.get("status", {}).get("code", ""), attrs=_attrs(sp.get("attributes")),
                            events=[{"name": e.get("name"), "attrs": _attrs(e.get("attributes"))} for e in sp.get("events", [])],
                            scope=ss.get("scope", {}).get("name", ""),
                        ))
        _trace_cache[trace_id] = out
    return _trace_cache[trace_id]


def by_name(trace_id: str) -> dict[str, Span]:
    return {s.name: s for s in spans(trace_id)}


def server_span(trace_id: str, parent_id: str) -> Span | None:
    return next((s for s in spans(trace_id) if s.kind == "SPAN_KIND_SERVER" and s.parent == parent_id), None)


def prometheus_names(selector: str) -> list[str]:
    q = urllib.parse.quote(selector)
    res = get_json(f"{GRAFANA}/api/datasources/proxy/uid/{ds_uid('Prometheus')}/api/v1/query?query={q}")
    return sorted({r["metric"]["__name__"] for r in res["data"]["result"]})


def loki_streams(query: str, start: datetime) -> list[dict]:
    q = urllib.parse.quote(query)
    start_ns = int(start.timestamp() * 1e9)
    res = get_json(f"{GRAFANA}/api/datasources/proxy/uid/{ds_uid('Loki')}/loki/api/v1/query_range?query={q}&start={start_ns}&limit=20")
    return res["data"]["result"]


# ---- Phase 1: drive an engine ---------------------------------------------------------------------

@dataclass
class Run:
    target: Target
    trace_id: str
    parent_id: str
    response: dict
    leak_bad: int
    coldbox: dict
    started: datetime
    fail: dict = field(default_factory=dict)   # unhandled-error request: trace id, parent id, HTTP status

    @property
    def scenarios(self) -> dict:
        return self.response.get("scenarios", {})

    def value(self, scenario: str):
        return self.scenarios.get(scenario, {}).get("value")


def drive(t: Target) -> Run:
    started = datetime.now(timezone.utc) - timedelta(minutes=5)
    app = f"{t.base}/cfml-otel/tests/app"
    trace_id, parent_id = hex_id(16), hex_id(8)
    response = get_json(f"{app}/scenarios.cfm?reinit=1&db={1 if t.db else 0}", traceparent(trace_id, parent_id))

    # Unhandled error through Application.cfc onError()
    fail = {"T": hex_id(16), "P": hex_id(8)}
    fail["status"] = http(f"{app}/fail.cfm", traceparent(fail["T"], fail["P"]))[0]

    # Leak protection: leak a scope, then hammer the pool and make sure nobody inherits it
    get_json(f"{app}/leak.cfm")
    leak_bad = 0
    for _ in range(40):
        ct = hex_id(16)
        if get_json(f"{app}/check.cfm", traceparent(ct, hex_id(8))).get("traceId") != ct:
            leak_bad += 1

    # ColdBox app (tests/coldbox): the repo loaded as an installed module, the way `box install` puts it
    cb: dict = {"error": ""}
    try:
        cb_base = f"{t.base}/cfml-otel/tests/coldbox/index.cfm"
        http(f"{cb_base}?fwreinit=1", timeout=180)
        cb["T"], cb["P"] = hex_id(16), hex_id(8)
        cb["index"] = get_json(f"{cb_base}?event=main.index", traceparent(cb["T"], cb["P"]))
        cb["FT"], cb["FP"] = hex_id(16), hex_id(8)
        cb["fail_status"] = http(f"{cb_base}?event=main.fail", traceparent(cb["FT"], cb["FP"]))[0]
        cb["LT"] = hex_id(16)
        cb["logbox"] = get_json(f"{cb_base}?event=main.logbox", traceparent(cb["LT"], hex_id(8)))
        cb["leak"] = get_json(f"{cb_base}?event=main.leak")
        cb["bad"] = 0
        for _ in range(30):
            ct = hex_id(16)
            if get_json(f"{cb_base}?event=main.check", traceparent(ct, hex_id(8))).get("traceId") != ct:
                cb["bad"] += 1
        # Reinit again: the module's onUnload() must shut the fallback SDK down, so this load starts a fresh one
        http(f"{cb_base}?fwreinit=1", timeout=180)
        cb["afterReinit"] = get_json(f"{cb_base}?event=main.index")
    except Exception as e:  # reported by the ColdBox tests, not a crash of the whole run
        cb["error"] = f"{type(e).__name__}: {e}"

    return Run(t, trace_id, parent_id, response, leak_bad, cb, started, fail)
