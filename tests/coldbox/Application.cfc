/**
 * ColdBox integration test app. dev/docker-compose.yml mounts ColdBox at /opt/coldbox and this repo as an
 * installed module at /opt/cbmodules/cfml-otel, the way `box install cfml-otel` would put it in modules/
 * (the *-sdk engines mount it under another folder name: the module must not depend on its folder's name).
 * Driven by the pytest runner in tests/integration.
 */
component {

    this.name = "cfml-otel-coldbox-tests";
    this.sessionManagement = false;
    this.setClientCookies = false;

    variables.appRoot = getDirectoryFromPath(getCurrentTemplatePath());
    this.mappings["/coldbox"] = "/opt/coldbox";
    this.mappings["/cbmodules"] = "/opt/cbmodules";
    this.mappings["/cbapp"] = variables.appRoot;
    // ColdBox can't change the classpath, so the host app loads the module's jars (see README)
    // (lib/sdk/ only matters with sdkFallback; harmless with the agent, which is what the agent jobs check)
    variables.moduleRoot = "/opt/cbmodules/" & directoryList("/opt/cbmodules", false, "name")[1];
    // bridge-only on the acf2023-serverapi engine, as in tests/app/Application.cfc
    variables.otelLoadPaths = (createObject("java", "java.lang.System").getenv("CFMLOTEL_BRIDGE_ONLY") ?: "") == "true"
        ? directoryList(variables.moduleRoot & "/lib/", false, "path", "cfml-otel-bridge-*.jar")
        : [variables.moduleRoot & "/lib/", variables.moduleRoot & "/lib/sdk/"];
    this.javaSettings = { loadPaths: variables.otelLoadPaths, loadColdFusionClassPath: true, reloadOnChange: false };

    COLDBOX_APP_ROOT_PATH = variables.appRoot;
    COLDBOX_APP_MAPPING = "cbapp";
    COLDBOX_CONFIG_FILE = "";
    COLDBOX_APP_KEY = "";
    COLDBOX_FAIL_FAST = true;
    COLDBOX_WEB_MAPPING = "";

    public boolean function onApplicationStart() {
        application.cbBootstrap = new coldbox.system.Bootstrap(
            COLDBOX_CONFIG_FILE, COLDBOX_APP_ROOT_PATH, COLDBOX_APP_KEY, COLDBOX_APP_MAPPING, COLDBOX_FAIL_FAST, COLDBOX_WEB_MAPPING
        );
        application.cbBootstrap.loadColdbox();
        return true;
    }

    public void function onApplicationEnd(struct appScope) {
        arguments.appScope.cbBootstrap.onApplicationEnd(arguments.appScope);
    }

    public boolean function onRequestStart(string targetPage) {
        return application.cbBootstrap.onRequestStart(arguments.targetPage);
    }

    // A handler that aborts bypasses the module's interceptor (README "ColdBox"), so clean up here
    public void function onAbort(string targetPage) {
        application.cbController.getWireBox().getInstance("OTel@cfmlotel").onAbort();
    }
}
