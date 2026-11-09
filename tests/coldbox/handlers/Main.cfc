/**
 * Handler for the ColdBox integration checks in tests/run-integration.ps1.
 */
component {

    property name="otel" inject="OTel@cfmlotel";

    // OTel@cfmlotel is injected, and spans from a handler nest under the agent's SERVER span
    function index(event, rc, prc) {
        var r = { "serverSpanId": otel.spanId(), "status": otel.status() };
        r["handler"] = otel.span("cb.handler", function(s) {
            return { "spanId": s.getSpanId(), "traceId": otel.traceId() };
        });
        r["currentAfter"] = otel.spanId();
        event.renderData(type = "json", data = r);
    }

    // Leaks a scope, then throws: the interceptor's onException must close the leaked scope and record
    // the error on the SERVER span (postProcess doesn't run when the event throws)
    function fail(event, rc, prc) {
        otel.startSpan("cb.leaked-before-error").makeCurrent();
        throw(type = "Custom.CbFail", message = "coldbox handler failure");
    }

    // Leaks a scope and returns normally: the interceptor's postProcess must close it
    function leak(event, rc, prc) {
        var s = otel.startSpan("cb.leaked");
        s.makeCurrent();
        s.end();
        event.renderData(type = "json", data = { "leakedSpanId": s.getSpanId() });
    }

    // Used after fail/leak: every pooled thread must start clean and continue the incoming trace
    function check(event, rc, prc) {
        event.renderData(type = "json", data = { "traceId": otel.traceId(), "spanId": otel.spanId() });
    }
}
