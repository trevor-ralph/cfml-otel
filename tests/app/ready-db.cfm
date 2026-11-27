<cfscript>
// Readiness probe for the integration harness (tests/integration/harness.py wait_until_ready). ACF installs the
// cfpm "sqlserver" package (installModules) during startup, and can answer requests before it is in place; a
// query through the built-in driver then fails with "The sqlserver package is not installed". Until this page
// returns 200, the database tests aren't ready to run.
setting showdebugoutput=false;
cfcontent(type = "application/json", reset = true);
queryExecute("SELECT 1 AS ok", {}, { datasource: "cfmlotel_mssql" });
writeOutput(serializeJSON({ "ok": true }));
</cfscript>
