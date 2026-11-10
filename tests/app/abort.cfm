<cfscript>
// Leaks a scope, then aborts. Application.cfc onAbort() -> otel.onAbort() must close the scope and (sdkFallback)
// end the SERVER span: neither engine runs onRequestEnd() after an abort.
setting showdebugoutput=false;
s = application.otel.startSpan("s30.leaked-before-abort");
s.makeCurrent();
s.end();
cfcontent(type = "application/json", reset = true);
writeOutput(serializeJSON({ "traceId": application.otel.traceId() }));
abort;
</cfscript>
