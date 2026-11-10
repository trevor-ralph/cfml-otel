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
    # setRoute (on by default): no route pattern matched (?event=), so the request is named by its event
    assert server.name == "GET main.index" and server.attrs.get("http.route") == "main.index", (server.name, server.attrs)


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
    # ColdBox sets the 500 after announcing onException; the span ends once the app's exceptionHandler has run
    assert server.attrs.get("http.response.status_code") == 500, server.attrs


def test_exception_handler_status_is_recorded(cb):
    """The app's exceptionHandler turns the error into a 404: the span records 404 and the exception, not ERROR."""
    assert cb["notfound_status"] == 404, cb["notfound_status"]
    server = harness.server_span(cb["NT"], cb["NP"])
    assert server is not None, [s.name for s in harness.spans(cb["NT"])]
    assert server.attrs.get("http.response.status_code") == 404, server.attrs
    assert server.status != "STATUS_CODE_ERROR", (server.status, server.attrs)
    assert any("Custom.CbNotFound" in (t or "") for t in server.event_attr("exception", "exception.type")), server.events


def test_scopes_leaked_by_events_are_closed(cb):
    assert cb["bad"] == 0, f"{cb['bad']} of 30 pooled requests inherited a stale trace"


def test_handler_abort_is_cleaned_up_by_onabort(cb):
    assert cb["abort_status"] == 200, cb["abort_status"]
    assert harness.server_span(cb["AT"], cb["AP"]) is not None, [s.name for s in harness.spans(cb["AT"])]
    assert cb["abort_bad"] == 0, f"{cb['abort_bad']} of 30 pooled requests inherited the aborted request's trace"


def _relocate_span(trace_id: str, parent_id: str):
    """The ColdBox request's SERVER span (the followed redirect lands on the plain app, in the same trace)."""
    return next((s for s in harness.spans(trace_id) if s.kind == "SPAN_KIND_SERVER" and s.parent == parent_id
                 and s.attrs.get("coldbox.event") == "main.redirect"), None)


def test_relocate_records_the_redirect_status(cb):
    assert cb["redirect_status"] == 200, cb["redirect_status"]   # the runner follows the redirect
    server = _relocate_span(cb["RT"], cb["RP"])
    assert server is not None, [(s.name, s.attrs) for s in harness.spans(cb["RT"])]
    assert server.attrs.get("http.response.status_code") == 302, server.attrs


def test_relocate_before_onabort_was_seen_has_no_wrong_status(run, cb):
    server = _relocate_span(cb["RT0"], cb["RP0"])
    assert server is not None, [(s.name, s.attrs) for s in harness.spans(cb["RT0"])]
    if run.target.sdk:
        # ended at postProcess, before the redirect set the status: unknown beats a wrong 200
        assert "http.response.status_code" not in server.attrs, server.attrs
    else:
        assert server.attrs.get("http.response.status_code") == 302, server.attrs


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
