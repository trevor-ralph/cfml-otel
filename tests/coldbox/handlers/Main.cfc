/**
 * Handler for the ColdBox integration checks in tests/integration/test_coldbox.py.
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

    // Logs through LogBox (CFAppender -> cflog) with a unique marker, inside the request's trace
    function logbox(event, rc, prc) {
        var marker = "lb" & lCase(hash(createUUID()));
        log.info("logbox #marker#");
        event.renderData(type = "json", data = { "marker": marker, "traceId": otel.traceId() });
    }

    // Leaks a scope, then throws: the interceptor's onException must close the leaked scope and record
    // the error on the SERVER span (postProcess doesn't run when the event throws)
    function fail(event, rc, prc) {
        otel.startSpan("cb.leaked-before-error").makeCurrent();
        throw(type = "Custom.CbFail", message = "coldbox handler failure");
    }

    // Throws an error that the app's exceptionHandler (onAppError) answers with a 404, not a 500: the SERVER span
    // must carry the status the handler chose, and no ERROR status
    function notFound(event, rc, prc) {
        throw(type = "Custom.CbNotFound", message = "no such thing");
    }

    // The app's exceptionHandler (config/Coldbox.cfc). ColdBox has already set 500; a not-found error becomes a 404
    function onAppError(event, rc, prc) {
        if (prc.exception.getType() == "Custom.CbNotFound") event.setHTTPHeader(statusCode = 404);
    }

    // Leaks a scope and returns normally: the interceptor's postProcess must close it
    function leak(event, rc, prc) {
        var s = otel.startSpan("cb.leaked");
        s.makeCurrent();
        s.end();
        event.renderData(type = "json", data = { "leakedSpanId": s.getSpanId() });
    }

    // Leaks a scope, then aborts inside the handler: no interceptor runs after that, so the app's
    // Application.cfc onAbort() -> otel.onAbort() has to clean up
    function abortNow(event, rc, prc) {
        otel.startSpan("cb.leaked-before-abort").makeCurrent();
        abort;
    }

    // relocate() announces postProcess and then redirects (to the plain test app's check page)
    function redirect(event, rc, prc) {
        relocate(URI = "/cfml-otel/tests/app/check.cfm");
    }

    // Used after fail/leak/abortNow: every pooled thread must start clean and continue the incoming trace
    function check(event, rc, prc) {
        event.renderData(type = "json", data = { "traceId": otel.traceId(), "spanId": otel.spanId() });
    }
}
