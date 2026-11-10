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
    this.version = "0.2.0";
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
            "logDiagnostics": true,
            "cfhttpSpans": "auto",
            // No javaagent: run cfml-otel's own SDK (add lib/sdk/ to loadPaths too). See README "Without the agent".
            "sdkFallback": false,
            "serviceName": "",
            // Name each request by its ColdBox route ("GET /api/users/:id/") or, without one, its event
            // ("GET main.index"), on the SERVER span and the agent's http.server.request.duration (otel.setRoute())
            "setRoute": true,
            // Tag the agent's SERVER span with coldbox.event / coldbox.route attributes
            "traceEvents": true
        };

        // ColdBox merges an app's overrides from moduleSettings["cfmlotel"] (this module's modelNamespace) after
        // configure(). Also accept moduleSettings["cfml-otel"], the module's folder name, which the 0.1.0 README
        // documented; "cfmlotel" wins where both set a key.
        try {
            var appModuleSettings = controller.getConfigSettings().coldboxConfig.getPropertyMixin("moduleSettings", "variables", {});
            if (structKeyExists(appModuleSettings, "cfml-otel") && isStruct(appModuleSettings["cfml-otel"])) {
                structAppend(settings, appModuleSettings["cfml-otel"], true);
            }
        } catch (any ignored) {}

        interceptors = [
            { class: "#moduleMapping#.interceptors.RequestLifecycle", name: "RequestLifecycle@cfmlotel" }
        ];

        // ColdBox registers a module under its folder's name, which box install makes "cfml-otel" but which
        // can be anything (a renamed checkout, a versioned folder): look the settings up by the real one.
        var registeredName = listLast(replace(modulePath, "\", "/", "all"), "/");
        var settingsDsl = "coldbox:moduleSettings:#registeredName#";

        // Mapped here, not in onLoad(): ColdBox creates the module's interceptors (which inject
        // OTel@cfmlotel) before it calls onLoad(). The settings are resolved when OTel is first built,
        // so the app's moduleSettings overrides are included.
        binder.map("OTel@cfmlotel")
            .to("#moduleMapping#.models.OTel")
            .initArg(name = "config", dsl = settingsDsl)
            .asSingleton();
        binder.map("settings@cfmlotel").toDSL(settingsDsl);
    }

    /**
     * On reinit and application end: flush, and in sdkFallback mode shut the SDK down, so a reinit starts a
     * fresh one instead of leaking the old exporters. Only if OTel was built: never construct it just to stop it.
     */
    function onUnload() {
        try {
            var mapping = wirebox.getBinder().getMapping("OTel@cfmlotel");
            if (wirebox.getScope("singleton").exists(mapping)) {
                wirebox.getInstance("OTel@cfmlotel").shutdown();
            }
        } catch (any ignored) {}
    }
}
