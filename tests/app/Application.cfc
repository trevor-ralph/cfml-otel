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

    // Test-only (not part of the wiring): an in-memory H2 database for the cfquery scenario. The H2 driver
    // is in the server's lib folder (dev/docker-compose.yml). The two engines spell a JDBC datasource differently.
    variables.h2Url = "jdbc:h2:mem:cfmlotel;DB_CLOSE_DELAY=-1";
    if (structKeyExists(server, "lucee")) {
        this.datasources["cfmlotel_h2"] = { "class": "org.h2.Driver", "connectionString": variables.h2Url, "username": "sa", "password": "" };
    } else {
        this.datasources["cfmlotel_h2"] = { "driver": "other", "class": "org.h2.Driver", "url": variables.h2Url, "username": "sa", "password": "" };
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
