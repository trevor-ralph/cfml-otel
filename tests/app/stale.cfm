<cfscript>
// sdkFallback only: a context left current on the pooled thread (a request that ended without cleanup) must not
// become the parent of the next request's SERVER span. Simulated inside one request, so no thread stays
// polluted: end this request's SERVER span, leave a span current, then start "the next request".
// Call it without a traceparent header.
setting showdebugoutput=false;
otel = application.otel;
out = { "mode": otel.status().mode };
if (out.mode == "sdk") {
    otel.onRequestEnd();
    stale = otel.startSpan("s31.stale", { "parent": "root" });
    token = stale.makeCurrent();
    out["staleTraceId"] = stale.getTraceId();
    out["currentBefore"] = otel.traceId();
    otel.onRequestStart();
    out["nextTraceId"] = otel.traceId();
    otel.onRequestEnd();
    otel.closeScope(token);
    stale.end();
}
cfcontent(type = "application/json", reset = true);
writeOutput(serializeJSON(out));
</cfscript>
