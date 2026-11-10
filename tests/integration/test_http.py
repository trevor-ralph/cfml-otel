"""httpSpan() / http(): exactly one CLIENT span per outbound call on every engine (made by the helper, or by the
agent where it traces cfhttp correctly), with the stable HTTP semantic-convention attributes."""
from __future__ import annotations

import pytest

import harness


def _client_spans_under(run, wrapper: str) -> list[harness.Span]:
    all_spans = harness.spans(run.trace_id)
    root = next(s for s in all_spans if s.name == wrapper)
    ids, out, grew = {root.id}, [], True
    while grew:
        grew = False
        for s in all_spans:
            if s.parent in ids and s.id not in ids:
                ids.add(s.id)
                grew = True
                if s.kind == "SPAN_KIND_CLIENT":
                    out.append(s)
    return out


def _the_client_span(run, wrapper: str) -> harness.Span:
    spans = _client_spans_under(run, wrapper)
    assert len(spans) == 1, [(s.name, s.scope) for s in spans]
    return spans[0]


def test_http_mode_matches_the_engine(run):
    # ACF: the agent's HttpClient instrumentation is on and correct, so the helpers leave the span to it.
    # Lucee: always the helper's own span (the agent's spans start orphan traces there, LDEV-6519).
    assert run.response["status"]["httpMode"] == ("agent" if run.target.is_acf and not run.target.sdk else "span")


@pytest.mark.parametrize("wrapper", ["s21.wrap", "s22.wrap", "s23.wrap", "s24.wrap"])
def test_one_client_span_per_call(run, wrapper):
    s = _the_client_span(run, wrapper)
    agent_mode = run.target.is_acf and not run.target.sdk
    assert s.scope.startswith("io.opentelemetry.apache-httpclient") if agent_mode else s.scope == "cfml-otel-tests", s.scope


def test_httpspan_attributes_and_name(run):
    s = _the_client_span(run, "s21.wrap")
    assert s.attrs["http.request.method"] == "GET"
    assert s.attrs["server.address"] == "127.0.0.1"
    assert isinstance(s.attrs["server.port"], int) and s.attrs["server.port"] > 0
    assert s.attrs["url.full"].endswith("/echo.cfm")
    assert s.attrs["http.response.status_code"] == 200
    assert s.status != "STATUS_CODE_ERROR"
    if not (run.target.is_acf and not run.target.sdk):
        assert s.name == "GET /echo.cfm" and s.attrs["url.template"] == "/echo.cfm"


def test_httpspan_downstream_continues_the_trace_from_the_client_span(run, engine):
    s = _the_client_span(run, "s21.wrap")
    received = run.value("httpSpan")["traceparent"]
    if engine == "lucee6" and received.split("-")[1:3] != [run.trace_id, s.id]:
        pytest.xfail(f"LDEV-6519 control: agent overwrote traceparent on Lucee's worker thread ({received})")
    assert received.split("-")[1:3] == [run.trace_id, s.id], (received, s.id)


def test_http_sends_method_headers_and_body(run, engine):
    echo = run.value("httpPost")
    assert echo["method"] == "POST" and echo["xTest"] == "yes" and echo["body"] == "hello body", echo
    if not (engine == "lucee6"):
        assert echo["traceparent"].split("-")[1] == run.trace_id, echo
    assert _the_client_span(run, "s22.wrap").attrs["http.request.method"] == "POST"


def test_http_4xx_marks_the_client_span_as_error(run):
    assert run.value("http404")["statusCode"].startswith("404"), run.value("http404")
    s = _the_client_span(run, "s23.wrap")
    assert s.attrs["http.response.status_code"] == 404
    assert s.attrs.get("error.type") == "404"
    assert s.status == "STATUS_CODE_ERROR"


def test_http_connection_failure_marks_the_client_span_as_error(run):
    assert not run.value("httpConnectionFailure")["statusCode"][:3].isdigit(), run.value("httpConnectionFailure")
    s = _the_client_span(run, "s24.wrap")
    assert s.status == "STATUS_CODE_ERROR"
    assert s.attrs.get("error.type"), s.attrs
