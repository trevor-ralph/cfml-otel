component {

    function configure() {
        coldbox = {
            "appName": "cfml-otel ColdBox tests",
            "reinitPassword": "",
            "handlerCaching": true,
            "eventCaching": false,
            // the repo, mounted as an installed module (see tests/coldbox/Application.cfc)
            "modulesExternalLocation": ["/cbmodules"]
        };

        moduleSettings = {
            // ColdBox's own override key: the module's modelNamespace (test_coldbox.py checks the tracer name)
            "cfmlotel": { "tracerName": "cfml-otel-coldbox-tests", "tracerVersion": "0.1.0" },
            // the folder-name key the 0.1.0 README documented, still merged by ModuleConfig.cfc. The no-agent
            // test engines (dev/docker-compose.yml *-sdk services) set CFMLOTEL_SDK_FALLBACK=true.
            "cfml-otel": { "sdkFallback": (createObject("java", "java.lang.System").getenv("CFMLOTEL_SDK_FALLBACK") ?: "") == "true" }
        };
    }
}
