/**
 * A second application in the same JVM that uses the test app's cfml-otel instance through the server scope
 * (the shared-instance pattern in the README). On purpose it has no /cfmlotel mapping and no javaSettings:
 * the shared instance must not depend on the calling application's mappings or classpath.
 */
component {
    this.name = "cfmlotel_shared_instance_tests";

    function onRequestStart(targetPage) {
        // sdkFallback: the SERVER span; with the agent a no-op apart from scope cleanup (as in tests/app)
        if (structKeyExists(server, "cfmlotelShared")) server.cfmlotelShared.onRequestStart();
        return true;
    }

    function onRequestEnd(targetPage) {
        if (structKeyExists(server, "cfmlotelShared")) server.cfmlotelShared.onRequestEnd();
    }
}
