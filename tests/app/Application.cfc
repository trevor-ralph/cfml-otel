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
