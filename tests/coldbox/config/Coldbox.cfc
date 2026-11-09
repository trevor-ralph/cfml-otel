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
            "cfml-otel": { "tracerName": "cfml-otel-coldbox-tests", "tracerVersion": "0.1.0" }
        };
    }
}
