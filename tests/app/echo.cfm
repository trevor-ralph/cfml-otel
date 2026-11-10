<cfscript>
setting showdebugoutput=false;
req = getHttpRequestData();
h = req.headers;
if (structKeyExists(url, "status")) cfheader(statuscode = url.status);
cfcontent(type = "application/json", reset = true);
writeOutput(serializeJSON({
    "traceparent": structKeyExists(h, "traceparent") ? h.traceparent : "",
    "method": cgi.request_method,
    "xTest": structKeyExists(h, "X-Test") ? h["X-Test"] : "",
    "body": isBinary(req.content) ? charsetEncode(req.content, "utf-8") : toString(req.content)
}));
</cfscript>
