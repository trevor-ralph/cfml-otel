<cfscript>
// Readiness probe for the integration harness (tests/integration/harness.py wait_until_ready). ACF answers
// requests before its cfpm "sqlserver" package is in place (the harness installs it with
// dev/acf-install-packages.cfm); until then a query through the built-in driver fails with "The sqlserver
// package is not installed". Until this page returns 200, the database tests aren't ready to run.
setting showdebugoutput=false;
cfcontent(type = "application/json", reset = true);
queryExecute("SELECT 1 AS ok", {}, { datasource: "cfmlotel_mssql" });
writeOutput(serializeJSON({ "ok": true }));
</cfscript>
