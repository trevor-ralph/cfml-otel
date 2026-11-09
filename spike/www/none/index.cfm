<cfscript>
// PROBE_LABEL lets the server-classpath containers relabel the "none" strategy.
label = createObject("java", "java.lang.System").getenv("PROBE_LABEL");
strategy = isNull(label) ? "none" : label & "/none";
function javaClass(required string cn) { return createObject("java", cn); }
include "../_shared/probe.cfm";
</cfscript>
