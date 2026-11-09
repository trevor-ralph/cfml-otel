<cfscript>
setting showdebugoutput=false;
h = getHttpRequestData().headers;
cfcontent(type = "application/json", reset = true);
writeOutput(serializeJSON({ "traceparent": structKeyExists(h, "traceparent") ? h.traceparent : "" }));
</cfscript>
