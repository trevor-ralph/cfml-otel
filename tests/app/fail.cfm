<cfscript>
// Unhandled error: Application.cfc onError() -> otel.onError() must mark the SERVER span (agent or sdkFallback)
throw(type = "Custom.ServerFail", message = "unhandled on purpose");
</cfscript>
