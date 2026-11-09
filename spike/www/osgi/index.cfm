<cfscript>
strategy = "osgi";
function javaClass(required string cn) {
    var bundle = findNoCase("io.opentelemetry.context.", cn) == 1 ? "opentelemetry-context" : "opentelemetry-api";
    return createObject("java", cn, bundle, "1.67.0");
}
include "../_shared/probe.cfm";
</cfscript>
