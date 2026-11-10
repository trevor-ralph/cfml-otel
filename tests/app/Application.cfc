/**
 * Integration-test app. Also the reference for wiring cfml-otel into a plain (non-ColdBox) app.
 */
component {
    this.name = "cfmlotel_integration_tests";

    variables.repoRoot = createObject("java", "java.io.File")
        .init(getDirectoryFromPath(getCurrentTemplatePath()) & "../../").getCanonicalPath();

    this.mappings["/cfmlotel"] = variables.repoRoot;
    // 1. Put the OTel API jars + bridge jar on this app's classpath. lib/sdk/ is only needed for sdkFallback
    //    (no javaagent); loading it with the agent attached is harmless, which the agent test jobs confirm.
    this.javaSettings = { loadPaths: [ variables.repoRoot & "/lib/", variables.repoRoot & "/lib/sdk/" ],
        loadColdFusionClassPath: true, reloadOnChange: false };

    // Test-only (not part of the wiring): the SQL Server container for the cfquery scenario, through each
    // engine's own SQL Server driver: Lucee's bundled Microsoft driver, ACF's built-in "MSSQLServer" driver
    // (the cfpm "sqlserver" package). Host and throwaway password come from dev/docker-compose.yml.
    variables.jSystem = createObject("java", "java.lang.System");
    variables.dbHost = variables.jSystem.getenv("MSSQL_HOST") ?: "mssql";
    variables.dbPassword = variables.jSystem.getenv("MSSQL_PASSWORD") ?: "";
    if (structKeyExists(server, "lucee")) {
        this.datasources["cfmlotel_mssql"] = {
            "class": "com.microsoft.sqlserver.jdbc.SQLServerDriver",
            "bundleName": "org.lucee.mssql",
            "connectionString": "jdbc:sqlserver://#variables.dbHost#:1433;DatabaseName=master;encrypt=false",
            "username": "sa", "password": variables.dbPassword
        };
    } else {
        this.datasources["cfmlotel_mssql"] = {
            "driver": "MSSQLServer", "host": variables.dbHost, "port": 1433, "database": "master",
            "username": "sa", "password": variables.dbPassword
        };
        // The workaround for the built-in driver's missing db identity (README "Database queries"):
        // Microsoft's JDBC driver (dev/jdbc/mssql-jdbc.jar, in cfusion/lib) as an "Other" datasource
        this.datasources["cfmlotel_mssql_msdriver"] = {
            "driver": "other", "class": "com.microsoft.sqlserver.jdbc.SQLServerDriver",
            "url": "jdbc:sqlserver://#variables.dbHost#:1433;databaseName=master;encrypt=false",
            "username": "sa", "password": variables.dbPassword
        };
    }

    // 2. One facade per application. sdkFallback: the no-agent test jobs (dev/docker-compose.yml *-sdk
    //    services) set CFMLOTEL_SDK_FALLBACK=true; with the agent attached the option does nothing.
    function onApplicationStart() {
        application.otel = new cfmlotel.models.OTel({ "tracerName": "cfml-otel-tests", "tracerVersion": "0.1.0",
            "sdkFallback": (variables.jSystem.getenv("CFMLOTEL_SDK_FALLBACK") ?: "") == "true" });
        return true;
    }

    // 3. Start the request (the SERVER span in sdkFallback mode; the agent makes it otherwise)
    function onRequestStart(targetPage) {
        if (structKeyExists(url, "reinit")) {
            if (structKeyExists(application, "otel")) application.otel.shutdown();
            onApplicationStart();
        }
        application.otel.onRequestStart();
        return true;
    }

    // 4. Close any scopes the request leaked (protects pooled threads); ends the fallback SERVER span
    function onRequestEnd(targetPage) {
        application.otel.onRequestEnd();
    }

    // 5. Record unhandled errors on the SERVER span. Set the status first: in sdkFallback mode this call ends
    //    the SERVER span (no engine runs onRequestEnd() after onError()) and records the status it sees.
    function onError(exception, eventName) {
        cfheader(statuscode = 500);
        application.otel.onError(arguments.exception);
        cfcontent(type = "application/json", reset = true);
        writeOutput(serializeJSON({ "error": structKeyExists(arguments.exception, "message") ? arguments.exception.message : "error" }));
    }

    // 6. Flush (and in sdkFallback mode shut down) when the application stops
    function onApplicationEnd(appScope) {
        if (structKeyExists(arguments.appScope, "otel")) arguments.appScope.otel.shutdown();
    }
}
