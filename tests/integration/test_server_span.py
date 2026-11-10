"""The request's SERVER span: made by the agent, or by cfml-otel itself on the no-agent (sdkFallback) engines.
Same expectations either way, so an app can move between the two without its traces changing shape."""
from __future__ import annotations

import pytest

import harness


def test_server_span_attributes(run, server_id):
    server = harness.server_span(run.trace_id, run.parent_id)
    assert server is not None and server.id == server_id
    assert server.attrs["http.request.method"] == "GET"
    assert server.attrs["http.response.status_code"] == 200
    assert server.attrs["url.path"].endswith("/tests/app/scenarios.cfm"), server.attrs
    assert server.status != "STATUS_CODE_ERROR"
    if run.target.sdk:
        assert server.scope == "cfml-otel-tests", server.scope
        assert server.name == "GET /cfml-otel/tests/app/scenarios.cfm", server.name
        assert server.attrs["http.route"] == "/cfml-otel/tests/app/scenarios.cfm"
        assert server.attrs["url.scheme"] == "http" and server.attrs["server.port"] > 0, server.attrs
        assert "client.address" in server.attrs and "user_agent.original" in server.attrs, server.attrs
        # the request carried sig=topsecret: redacted like a CLIENT span's url.full
        assert "sig=REDACTED" in server.attrs["url.query"] and "topsecret" not in server.attrs["url.query"], server.attrs


def test_unhandled_error_marks_the_server_span(run):
    assert run.fail["status"] == 500, run.fail
    server = harness.server_span(run.fail["T"], run.fail["P"])
    assert server is not None, [s.name for s in harness.spans(run.fail["T"])]
    assert server.status == "STATUS_CODE_ERROR"
    assert "Custom.ServerFail" in server.event_attr("exception", "exception.type"), server.events
    assert server.attrs.get("http.response.status_code") == 500, server.attrs


def test_error_page_with_status_200_is_still_an_error(run):
    """An error page sent as 200: without onError() the agent would record a successful request."""
    assert run.fail["status200"] == 200, run.fail
    server = harness.server_span(run.fail["T200"], run.fail["P200"])
    assert server is not None, [s.name for s in harness.spans(run.fail["T200"])]
    assert server.status == "STATUS_CODE_ERROR", (server.status, server.attrs)
    assert "Custom.ServerFail" in server.event_attr("exception", "exception.type"), server.events


def _server_span_for(trace_id: str, parent_id: str, page: str):
    """The SERVER span of one page, where several requests share a trace (a followed redirect)."""
    return next((s for s in harness.spans(trace_id) if s.kind == "SPAN_KIND_SERVER" and s.parent == parent_id
                 and s.attrs.get("url.path", "").endswith(page)), None)


def test_aborted_request_ends_its_server_span_and_cleans_up(run):
    # cfabort: Application.cfc onAbort() -> otel.onAbort() (neither engine runs onRequestEnd() then)
    assert run.abort["status"] == 200, run.abort
    server = _server_span_for(run.abort["T"], run.abort["P"], "/abort.cfm")
    assert server is not None, [s.name for s in harness.spans(run.abort["T"])]
    assert run.abort["bad"] == 0, f"{run.abort['bad']} of 40 pooled requests inherited the aborted request's trace"


def test_cflocation_records_the_redirect(run):
    assert run.abort["redirect_status"] == 200, run.abort   # the runner follows the redirect to check.cfm
    server = _server_span_for(run.abort["RT"], run.abort["RP"], "/redirect.cfm")
    assert server is not None, [(s.name, s.attrs.get("url.path")) for s in harness.spans(run.abort["RT"])]
    assert server.attrs.get("http.response.status_code") == 302, server.attrs


def test_stale_thread_context_is_not_the_server_spans_parent(run):
    if not run.target.sdk:
        pytest.skip("agent engine: the agent makes the SERVER span")
    st = run.stale
    assert st["mode"] == "sdk" and st["currentBefore"] == st["staleTraceId"], st
    assert st["nextTraceId"] and st["nextTraceId"] != st["staleTraceId"], st
    assert harness.server_span(st["nextTraceId"], "") is not None, [s.name for s in harness.spans(st["nextTraceId"])]


def test_child_spans_and_leak_cleanup_keep_the_server_span_current(named, server_id):
    # closeLeakedScopes() mid-request (s16/s17) must not close the fallback's SERVER scope:
    # spans started afterwards still nest under it
    assert named["s16.outer"].parent == server_id
    assert named["s25.after-cleanup"].parent == server_id


def test_sdk_fallback_status(run):
    if not run.target.sdk:
        s = run.response["status"]
        assert s["mode"] == "agent" and s["sdkFallback"] == {}, s
        pytest.skip("agent engine: the fallback is off (sdkFallback not requested)")
    s = run.response["status"]
    assert s["mode"] == "sdk" and s["sdkFallback"]["started"], s
    assert s["sdkFallback"]["serviceName"] == run.target.service, s
    assert s["implementation"].startswith("io.opentelemetry.sdk."), s


def test_instance_shared_with_an_app_without_the_mapping(run):
    """tests/shared has no /cfmlotel mapping and no jars: span(), startSpan(), metrics must still work through the
    test app's instance in the server scope, inside the shared app's own request trace."""
    r = run.shared["response"]
    assert "error" not in r, r
    assert r["traceId"] == run.shared["T"] and r["manualIsCurrent"], r
    server = _server_span_for(run.shared["T"], run.shared["P"], "/tests/shared/index.cfm")
    assert server is not None, [(s.name, s.attrs.get("url.path")) for s in harness.spans(run.shared["T"])]
    child = next((s for s in harness.spans(run.shared["T"]) if s.name == "shared.child"), None)
    assert child is not None and child.id == r["childSpanId"] and child.parent == server.id, child
    assert child.attrs.get("shared.app") is True, child.attrs


def test_set_route_names_the_server_span(run):
    """otel.setRoute(): the SERVER span is named by the route (agent: through its route bridge; SDK fallback:
    cfml-otel's own span), the first route stays, and the agent's request-duration metric gets the label."""
    assert run.route["response"]["set"] is True, run.route
    server = _server_span_for(run.route["T"], run.route["P"], "/tests/app/route.cfm")
    assert server is not None, [(s.name, s.attrs.get("url.path")) for s in harness.spans(run.route["T"])]
    assert server.name == "GET cfmlotel.route.test", server.name
    assert server.attrs.get("http.route") == "cfmlotel.route.test", server.attrs
    if not run.target.sdk:
        # the agent's http.server.request.duration carries the route (the fallback records no HTTP metrics)
        q = f'http_server_request_duration_seconds_count{{service_name="{run.target.service}",http_route="cfmlotel.route.test"}}'
        res = harness.get_json(f"{harness.GRAFANA}/api/datasources/proxy/uid/{harness.ds_uid('Prometheus')}/api/v1/query?"
                               + harness.urllib.parse.urlencode({"query": q}))
        assert res["data"]["result"], q
