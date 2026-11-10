/**
 * Integration-test app. Also the reference for wiring cfml-otel into a plain (non-ColdBox) app.
 */
component {
    this.name = "cfmlotel_integration_tests";

    variables.repoRoot = createObject("java", "java.io.File")
        .init(getDirectoryFromPath(getCurrentTemplatePath()) & "../../").getCanonicalPath();

    this.mappings["/cfmlotel"] = variables.repoRoot;
    // 1. Put the OTel API jars + bridge jar on this app's classpath
    this.javaSettings = { loadPaths: [ variables.repoRoot & "/lib/" ], loadColdFusionClassPath: true, reloadOnChange: false };

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

    // 2. One facade per application
    function onApplicationStart() {
        application.otel = new cfmlotel.models.OTel({ "tracerName": "cfml-otel-tests", "tracerVersion": "0.1.0" });
        return true;
    }

    function onRequestStart(targetPage) {
        if (structKeyExists(url, "reinit")) onApplicationStart();
        return true;
    }

    // 3. Close any scopes the request leaked (protects pooled threads)
    function onRequestEnd(targetPage) {
        application.otel.onRequestEnd();
    }

    // 4. Record unhandled errors on the agent's SERVER span
    function onError(exception, eventName) {
        application.otel.onError(arguments.exception);
        cfheader(statuscode = 500);
        cfcontent(type = "application/json", reset = true);
        writeOutput(serializeJSON({ "error": structKeyExists(arguments.exception, "message") ? arguments.exception.message : "error" }));
    }
}
