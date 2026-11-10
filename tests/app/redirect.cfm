<cfscript>
// cflocation aborts the request: its SERVER span must still be ended, with the redirect's status
location(url = "check.cfm", addToken = false);
</cfscript>
