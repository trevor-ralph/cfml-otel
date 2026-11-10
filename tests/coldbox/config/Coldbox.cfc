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

        // LogBox through its CFAppender (cflog underneath): test_coldbox.py checks the agent ships it to Loki
        logBox = {
            "appenders": { "cflog": { "class": "coldbox.system.logging.appenders.CFAppender", "properties": { "fileName": "cfmlotel-logbox" } } },
            "root": { "levelMax": "INFO", "appenders": "*" }
        };

        moduleSettings = {
            // ColdBox's own override key: the module's modelNamespace (test_coldbox.py checks the tracer name)
            "cfmlotel": { "tracerName": "cfml-otel-coldbox-tests", "tracerVersion": "0.1.0" },
            // the folder-name key the 0.1.0 README documented, still merged by ModuleConfig.cfc. The no-agent
            // test engines (dev/docker-compose.yml *-sdk services) set CFMLOTEL_SDK_FALLBACK=true.
            // serviceName: only the fallback uses it; its own name proves apps sharing a class loader (Lucee 6)
            // still get separate SDKs
            "cfml-otel": { "sdkFallback": (createObject("java", "java.lang.System").getenv("CFMLOTEL_SDK_FALLBACK") ?: "") == "true",
                "serviceName": (createObject("java", "java.lang.System").getenv("OTEL_SERVICE_NAME") ?: "cfml-otel") & "-coldbox" }
        };
    }
}
