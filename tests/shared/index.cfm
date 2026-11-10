<cfscript>
// Everything a typical app calls, on an instance created by another application (tests/app)
setting showdebugoutput=false;
out = {};
try {
    otel = server.cfmlotelShared;
    out["childSpanId"] = otel.span("shared.child", function(s) {
        s.setAttribute("shared.app", true);
        return s.getSpanId();
    });
    started = otel.startSpan("shared.manual");
    token = started.makeCurrent();
    out["manualIsCurrent"] = otel.spanId() == started.getSpanId();
    otel.closeScope(token);
    started.end();
    otel.counter("cfmlotel.shared.calls").add(1);
    otel.histogram("cfmlotel.shared.duration", "", "ms").record(1.5);
    out["traceId"] = otel.traceId();
    out["noop"] = !otel.isEnabled();
} catch (any e) {
    out["error"] = e.message;
}
cfcontent(type = "application/json", reset = true);
writeOutput(serializeJSON(out));
</cfscript>
