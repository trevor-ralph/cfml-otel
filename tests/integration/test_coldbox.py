"""ColdBox app (tests/coldbox): the repo loaded as an installed module, with its request interceptor."""
from __future__ import annotations

import pytest

import harness


@pytest.fixture
def cb(run) -> dict:
    if run.coldbox.get("error"):
        pytest.fail(f"ColdBox requests failed: {run.coldbox['error'][:2000]}")
    return run.coldbox


def test_module_activated_injected_and_bridged(run, cb):
    s = cb["index"]["status"]
    assert s["active"] and s["mode"] == ("sdk" if run.target.sdk else "agent"), s


def test_interceptor_tags_the_server_span(cb):
    server = harness.server_span(cb["T"], cb["P"])
    assert server is not None
    assert server.attrs.get("coldbox.event") == "main.index", server.attrs


def test_app_module_settings_override_the_defaults(run, cb):
    # moduleSettings["cfmlotel"] sets the tracer name; moduleSettings["cfml-otel"] sets sdkFallback (sdk engines)
    handler = next(s for s in harness.spans(cb["T"]) if s.name == "cb.handler")
    assert handler.scope == "cfml-otel-coldbox-tests", handler.scope
    assert cb["index"]["status"]["mode"] == ("sdk" if run.target.sdk else "agent")


def test_handler_span_nests_under_the_server_span(cb):
    idx = cb["index"]
    server = harness.server_span(cb["T"], cb["P"])
    handler = harness.by_name(cb["T"]).get("cb.handler")
    assert idx["handler"]["traceId"] == cb["T"]
    assert server is not None and server.id == idx["serverSpanId"]
    assert handler is not None and handler.parent == server.id
    assert idx["currentAfter"] == idx["serverSpanId"]


def test_onexception_records_the_error_on_the_server_span(cb):
    server = harness.server_span(cb["FT"], cb["FP"])
    assert cb["fail_status"] == 500
    assert server is not None and server.status == "STATUS_CODE_ERROR"
    assert any("Custom.CbFail" in (t or "") for t in server.event_attr("exception", "exception.type")), server.events


def test_scopes_leaked_by_events_are_closed(cb):
    assert cb["bad"] == 0, f"{cb['bad']} of 30 pooled requests inherited a stale trace"


def test_reinit_shuts_the_fallback_sdk_down(run, cb):
    before, after = cb["index"]["status"], cb["afterReinit"]["status"]
    if not run.target.sdk:
        assert after["mode"] == "agent", after
        pytest.skip("agent engine: no SDK of cfml-otel's own to shut down")
    # The module's onUnload() shut the old SDK down, so a reinit replaces it instead of adding one. (Counted per
    # class loader: on Lucee 6 the plain test app's SDK shares it, so the count isn't simply 1.)
    assert after["mode"] == "sdk" and after["sdkFallback"]["started"], after["sdkFallback"]
    assert after["sdkFallback"]["runningInClassLoader"] == before["sdkFallback"]["runningInClassLoader"], (before["sdkFallback"], after["sdkFallback"])


def test_fallback_sdk_is_per_application(run, cb):
    if not run.target.sdk:
        pytest.skip("agent engine: the agent's SDK is shared by design")
    # The ColdBox app's serviceName option beats OTEL_SERVICE_NAME, and its SDK is its own even where both test
    # apps load cfml-otel through one class loader (Lucee 6): the plain app keeps the env var's name.
    assert cb["index"]["status"]["sdkFallback"]["serviceName"] == f"{run.target.service}-coldbox", cb["index"]["status"]
    assert run.response["status"]["sdkFallback"]["serviceName"] == run.target.service, run.response["status"]


def test_logbox_cfappender_reaches_loki_with_the_trace(run, cb):
    """LogBox's CFAppender writes through cflog, which the agent captures (log4j2)."""
    if run.target.sdk:
        pytest.xfail("cflog capture is the agent's; without it LogBox needs an OTel appender")
    lb = cb["logbox"]
    assert lb["traceId"] == cb["LT"], lb
    streams = harness.loki_streams(f'{{service_name="{run.target.service}"}} |= "{lb["marker"]}"', run.started)
    assert streams, f"no Loki line with {lb['marker']}"
    assert any(s["stream"].get("trace_id") == cb["LT"] for s in streams), [s["stream"] for s in streams]
