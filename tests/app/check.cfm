<cfscript>
setting showdebugoutput=false;
cfcontent(type = "application/json", reset = true);
writeOutput(serializeJSON({ "traceId": application.otel.traceId(), "spanId": application.otel.spanId() }));
</cfscript>
