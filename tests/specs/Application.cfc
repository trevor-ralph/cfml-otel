/**
 * TestBox unit specs for the CFML side of cfml-otel (tests/specs/*Spec.cfc). They run inside each engine
 * container, with or without the javaagent, and need no backend: tests/integration/test_specs.py calls
 * runner.cfm and fails on any failing spec. TestBox is mounted at /opt/testbox (dev/fetch-test-deps.sh).
 */
component {
    this.name = "cfmlotel_specs";
    this.sessionManagement = false;

    variables.repoRoot = createObject("java", "java.io.File")
        .init(getDirectoryFromPath(getCurrentTemplatePath()) & "../../").getCanonicalPath();
    this.mappings["/cfmlotel"] = variables.repoRoot;
    this.mappings["/testbox"] = "/opt/testbox";
    this.mappings["/specs"] = getDirectoryFromPath(getCurrentTemplatePath());
    // bridge-only on the acf2023-serverapi engine, as in tests/app/Application.cfc
    variables.otelLoadPaths = (createObject("java", "java.lang.System").getenv("CFMLOTEL_BRIDGE_ONLY") ?: "") == "true"
        ? directoryList(variables.repoRoot & "/lib/", false, "path", "cfml-otel-bridge-*.jar")
        : [ variables.repoRoot & "/lib/", variables.repoRoot & "/lib/sdk/" ];
    this.javaSettings = { loadPaths: variables.otelLoadPaths, loadColdFusionClassPath: true, reloadOnChange: false };
}
