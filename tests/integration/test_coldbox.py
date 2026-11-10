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
