<cfscript>
// Deliberately leaks a scope: makes a span current and never closes it. onRequestEnd() must clean up,
// otherwise the next request served by this pooled thread would inherit the span.
setting showdebugoutput=false;
s = application.otel.startSpan("s12.leaked");
tok = s.makeCurrent();
cfcontent(type = "application/json", reset = true);
writeOutput(serializeJSON({ "leakedSpanId": s.getSpanId(), "currentSpanId": application.otel.spanId() }));
</cfscript>
