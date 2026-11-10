"""Plain CFML app (tests/app): every scenario in scenarios.cfm, checked against what reached Tempo,
Prometheus and Loki."""
from __future__ import annotations

import pytest

import harness


def test_all_scenarios_ran_without_error(run):
    failed = {k: v.get("error") for k, v in run.scenarios.items() if not v.get("ok")}
    assert not failed


def test_status_enabled_bridged_active(run):
    s = run.response["status"]
    assert s["enabled"] and s["agentBridged"] and s["active"], s


def test_request_continues_incoming_trace(run):
    assert run.response["traceId"] == run.trace_id


def test_tempo_has_the_server_span(run, server_id):
    server = harness.server_span(run.trace_id, run.parent_id)
    assert server is not None and server.id == server_id


# ---- spans ------------------------------------------------------------------------------------------

def test_nested_return_value_and_context(run, server_id):
    n = run.value("nested")
    assert n["returned"] == "ret"
    assert n["innerTraceId"] == run.trace_id
    assert n["currentInInner"] == n["innerSpanId"]
    assert n["currentAfter"] == server_id


def test_nested_tempo_parentage(named, server_id):
    assert named["s2.outer"].parent == server_id
    assert named["s2.inner"].parent == named["s2.outer"].id


def test_nested_attribute_types(named):
    a = named["s2.outer"].attrs
    assert a["t.str"] == "x"
    assert a["t.num"] == 42 and isinstance(a["t.num"], int)
    assert a["t.dbl"] == 1.5
    assert a["t.bool"] is True
    assert a["t.arr"] == ["a", "b"]
    assert a["t.nums"] == [1, 2, 3]


def test_exception_rethrown_with_original_type_context_restored(run, server_id):
    x = run.value("exception")
    assert x["thrown"] and x["type"] == "Custom.Fail" and x["currentAfter"] == server_id


def test_exception_span_error_and_event(named):
    f = named["s3.fails"]
    assert f.status == "STATUS_CODE_ERROR"
    assert "exception" in [e["name"] for e in f.events]


def test_exception_type_is_the_cfml_type(named):
    assert named["s3.fails"].event_attr("exception", "exception.type") == ["Custom.Fail"]


def test_java_exception_recorded_with_java_type(named):
    types = named["s14.java-exception"].event_attr("exception", "exception.type")
    assert any("NumberFormatException" in (t or "") for t in types), types


def test_manual_startspan_makecurrent_closescope(run, named, server_id):
    m = run.value("manual")
    assert m["currentInside"] == m["spanId"] and m["currentAfter"] == server_id
    assert named["s6.child"].parent == m["spanId"]
    assert named["s6.manual"].parent == server_id


def test_root_span_starts_a_new_trace(run):
    assert run.value("root") and run.value("root") != run.trace_id


def test_disabled_instance_is_a_noop(run):
    d = run.value("disabled")
    assert d["value"] == 5 and not d["enabled"] and d["traceId"] == ""


def test_currentspan_end_does_not_end_server_span(named, server_id):
    assert named["s15.after-borrowed-end"].parent == server_id


# ---- threads ----------------------------------------------------------------------------------------

def test_cfthread_without_bindcontext(run):
    """Documents engine behaviour: cfthread doesn't inherit the trace context on any engine."""
    if run.value("cfthreadUnbound") != run.trace_id:
        pytest.xfail("cfthread doesn't inherit context (expected on every engine; use bindContext)")


def test_cfthread_with_bindcontext(run, named, server_id):
    assert run.value("cfthreadBound")["traceId"] == run.trace_id
    assert named["s4.in-thread"].parent == server_id


def test_runasync_keeps_the_trace(run, named, server_id):
    assert run.value("runAsync")["traceId"] == run.trace_id
    assert named["s5.async"].parent == server_id


# ---- propagation ------------------------------------------------------------------------------------

def test_cfhttp_injected_traceparent_is_this_trace(run, named):
    h = run.value("cfhttp")
    assert h["sent"].split("-")[1] == run.trace_id
    assert named["s7.client"].kind == "SPAN_KIND_CLIENT"


def test_cfhttp_downstream_received_this_trace(run, engine):
    h = run.value("cfhttp")
    received = h["received"].split("-")[1] if h.get("received") else ""
    if engine == "lucee6" and received != run.trace_id:
        # Lucee 6 keeps the agent's HttpClient instrumentation on as a control (dev/docker-compose.yml)
        pytest.xfail(f"LDEV-6519 control: agent overwrote traceparent on Lucee's worker thread ({h['received']})")
    assert received == run.trace_id, h


def test_extractcontext_joins_remote_trace(run):
    x = run.value("extract")
    remote = harness.by_name(x["expectTraceId"]).get("s8.remote-parent")
    assert x["traceId"] == x["expectTraceId"]
    assert remote is not None and remote.parent == x["expectParentId"]


# ---- scope safety -----------------------------------------------------------------------------------

def test_scope_leaked_inside_span_or_closed_out_of_order_is_cleaned_up(run, server_id):
    lk = run.value("leakInsideSpan")
    assert lk["currentAfterSpan"] == server_id
    assert lk["currentAfterOuterClose"] == server_id
    assert lk["leftOpen"] == 0


def test_leaked_scope_closed_at_request_end(run):
    assert run.leak_bad == 0, f"{run.leak_bad} of 40 pooled requests inherited a stale trace"


def test_scope_closed_early_keeps_result_and_original_exception(run, named, server_id):
    ce = run.value("scopeClosedEarly")
    assert ce["spanValue"] == "value" and ce["contextValue"] == "ctx"
    assert ce["thrownType"] == "Custom.Original"
    assert ce["currentAfter"] == server_id
    assert named["s17.closed-early"].parent == server_id


# ---- cfquery (SQL Server) ---------------------------------------------------------------------------

needs_mssql = pytest.mark.skipif(not harness.MSSQL, reason="MSSQL=0: no SQL Server container")


def _db_attr(span: harness.Span, *keys: str):
    # attribute names differ between DB semantic-convention versions
    return next((span.attrs[k] for k in keys if k in span.attrs), None)


@needs_mssql
def test_cfquery_returned_the_row(run):
    q = run.value("cfquery")
    assert q["rows"] == 1 and q["name"] == "first", q


@needs_mssql
def test_cfquery_jdbc_spans_nest_under_the_cfml_otel_span(run, named, server_id):
    db = named["s18.db"]
    assert db.parent == server_id
    kids = [s for s in harness.spans(run.trace_id) if s.parent == db.id and s.kind == "SPAN_KIND_CLIENT"]
    selects = [s for s in kids if "cfmlotel_items" in (_db_attr(s, "db.query.text", "db.statement") or "")
               and (_db_attr(s, "db.query.text", "db.statement") or "").lstrip().upper().startswith("SELECT")]
    assert selects, [s.name for s in kids]


@needs_mssql
def test_cfquery_spans_identify_sql_server(run, named):
    db = named["s18.db"]
    kids = [s for s in harness.spans(run.trace_id) if s.parent == db.id and s.kind == "SPAN_KIND_CLIENT"]
    systems = {_db_attr(s, "db.system.name", "db.system") for s in kids}
    if run.target.is_acf and systems == {"other_sql"}:
        # ACF's built-in driver uses jdbc:macromedia:sqlserver:// URLs, which the agent's JDBC URL parser
        # doesn't recognise: db.system is other_sql and server.address / server.port / db.name are missing.
        # Queries are still traced (see the test above). README: "Database queries (cfquery)".
        pytest.xfail("agent doesn't parse ACF's jdbc:macromedia:sqlserver:// URLs (db.system=other_sql)")
    assert systems == {"mssql"}, {s.name: _db_attr(s, "db.system.name", "db.system") for s in kids}
    assert all(s.attrs.get("server.address") == "mssql" for s in kids), [s.attrs for s in kids]


@needs_mssql
def test_cfquery_acf_microsoft_driver_identifies_sql_server(run, named):
    """The workaround for ACF's built-in driver: Microsoft's JDBC driver as an "Other" datasource."""
    if not run.target.is_acf:
        pytest.skip("ACF only (Lucee already uses Microsoft's driver)")
    q = run.value("cfqueryMsDriver")
    assert q and q["rows"] == 1 and q["name"] == "first", run.scenarios.get("cfqueryMsDriver")
    db = named["s19.db-msdriver"]
    kids = [s for s in harness.spans(run.trace_id) if s.parent == db.id and s.kind == "SPAN_KIND_CLIENT"]
    assert kids, "no JDBC spans under s19.db-msdriver"
    for s in kids:
        assert _db_attr(s, "db.system.name", "db.system") == "mssql", s.attrs
        assert s.attrs.get("server.address") == "mssql" and s.attrs.get("server.port") == 1433, s.attrs
        assert _db_attr(s, "db.namespace", "db.name") == "master", s.attrs


# ---- metrics and logs -------------------------------------------------------------------------------

def test_metrics_long_instruments_round_doubles_keep_fractions(run):
    m = run.value("metrics")
    assert m["rounded"] == 1 and m["whole"] == 3 and m["double"] == 0.7, m


def test_metrics_reach_prometheus(run):
    names = harness.prometheus_names(f'{{__name__=~"cfmlotel_test.*",job="{run.target.service}"}}')
    missing = [w for w in ("calls", "latency", "level", "inflight")
               if not any(n.startswith(f"cfmlotel_test_{w}") for n in names)]
    assert not missing, names


def test_logs_reach_loki_correlated_with_the_trace(run):
    marker = run.value("logs")["marker"]
    streams = harness.loki_streams(f'{{service_name="{run.target.service}"}} |= "{marker}"', run.started)
    lines = [v for s in streams for v in s["values"]]
    assert len(lines) >= 2, streams
    assert any(s["stream"].get("trace_id") == run.trace_id for s in streams), [s["stream"] for s in streams]
