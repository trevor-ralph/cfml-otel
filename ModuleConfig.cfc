/**
 * ColdBox module wrapper. Non-ColdBox apps don't need this file: see README "Plain CFML apps".
 *
 * NOTE: ColdBox can't add jars to the classpath for you. The host Application.cfc must include this
 * module's lib/ folder in this.javaSettings.loadPaths (see README).
 */
component {

    this.title = "cfml-otel";
    this.author = "";
    this.description = "OpenTelemetry for CFML (Lucee + Adobe ColdFusion), on top of the OTel javaagent";
    this.version = "0.1.0";
    this.cfmapping = "cfmlotel";
    this.modelNamespace = "cfmlotel";
    this.autoMapModels = false;

    function configure() {
        settings = {
            "enabled": true,
            "tracerName": "cfml-otel",
            "tracerVersion": "",
            "meterName": "",
            "loggerName": "",
            "logLeakedScopes": true,
            // Wrap every ColdBox event in a span named "<event>" under the agent's SERVER span
            "traceEvents": true
        };

        interceptors = [
            { class: "#moduleMapping#.interceptors.RequestLifecycle", name: "RequestLifecycle@cfmlotel" }
        ];
    }

    function onLoad() {
        binder.map("OTel@cfmlotel")
            .to("#moduleMapping#.models.OTel")
            .initArg(name = "config", value = settings)
            .asSingleton();
    }
}
