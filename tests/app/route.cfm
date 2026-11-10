<cfscript>
// otel.setRoute(): names the request by its route, not its file. The second call is shorter, so it's ignored
// (the agent's rule: at the same level the first route stays unless a longer one comes).
setting showdebugoutput=false;
out = { "set": application.otel.setRoute("cfmlotel.route.test") };
application.otel.setRoute("ignored");
out["traceId"] = application.otel.traceId();
cfcontent(type = "application/json", reset = true);
writeOutput(serializeJSON(out));
</cfscript>
