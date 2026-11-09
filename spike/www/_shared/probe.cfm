<cfscript>
/*
 * Classloading probe. Included by each strategy's index.cfm, which must define:
 *   strategy      - label for this load strategy
 *   javaClass(cn) - function returning createObject("java", cn, ...) for this strategy
 * Emits JSON describing whether CFML-side OTel API calls reach the agent's SDK.
 */
setting showdebugoutput=false;
result = [:];
result["strategy"] = strategy;
result["engine"] = structKeyExists(server, "lucee")
    ? "Lucee " & server.lucee.version
    : server.coldfusion.productname & " " & server.coldfusion.productversion;

hdrs = getHttpRequestData().headers;
result["incomingTraceparent"] = structKeyExists(hdrs, "traceparent") ? hdrs.traceparent : "";
incomingTraceId = listLen(result.incomingTraceparent, "-") == 4 ? listGetAt(result.incomingTraceparent, 2, "-") : "";

function attempt(required string key, required any fn) {
    try {
        result[key] = { "ok": true, "value": fn() };
    } catch (any e) {
        result[key] = { "ok": false, "error": e.type & ": " & e.message & (len(e.detail) ? " | " & e.detail : "") };
    }
}

function spanIds(span) {
    var sc = span.getSpanContext();
    return { "traceId": sc.getTraceId(), "spanId": sc.getSpanId(), "valid": sc.isValid() };
}

// 1. Can we see the API at all, and what implementation does GlobalOpenTelemetry hand back?
attempt("globalOpenTelemetry", function() {
    var otel = javaClass("io.opentelemetry.api.GlobalOpenTelemetry").get();
    var tp = otel.getTracerProvider();
    return {
        "otelClass": otel.getClass().getName(),
        "otelClassLoader": otel.getClass().getClassLoader().toString(),
        "tracerProviderClass": tp.getClass().getName()
    };
});

// 2. Does Span.current() see the agent's servlet SERVER span?
attempt("currentSpan", function() {
    return spanIds(javaClass("io.opentelemetry.api.trace.Span").current());
});

// 3a. Custom span, calling methods directly on the returned objects (engine reflects on the concrete class).
//     Each step is recorded so we can see exactly which call breaks.
attempt("customSpan", function() {
    var steps = [];
    // NB: CFML is case-insensitive -- "Span" and "span" would be the same variable.
    var SpanStatic = javaClass("io.opentelemetry.api.trace.Span");
    apiLoader = javaClass("io.opentelemetry.api.GlobalOpenTelemetry").get().getClass().getClassLoader();
    var tracer = javaClass("io.opentelemetry.api.GlobalOpenTelemetry").getTracer("cfml-spike");
    var span = tracer.spanBuilder("probe.custom.direct").startSpan();
    var out = spanIds(span);
    out["spanClass"] = span.getClass().getName();
    var step = function(name, fn) {
        try { fn(); arrayAppend(steps, name & ": ok"); }
        catch (any e) { arrayAppend(steps, name & ": " & e.type & " " & e.message); out["failed"] = true; }
    };
    var h = {};
    step("setAttribute", function() { span.setAttribute(javacast("string", "probe.strategy"), javacast("string", strategy)); });
    step("makeCurrent", function() { h.scope = span.makeCurrent(); out["scopeClass"] = h.scope.getClass().getName(); });
    step("Span.current", function() { out["currentAfterMakeCurrent"] = SpanStatic.current().getSpanContext().getSpanId(); });
    step("scope.close", function() {
        try { h.scope.close(); }
        catch (any e) {
            // A failed close leaks this span onto the pooled request thread; always clean up via the interface.
            invokeVia(h.scope, "io.opentelemetry.context.Scope", "close");
            rethrow;
        }
    });
    step("span.end", function() { span.end(); });
    out["steps"] = steps;
    if (structKeyExists(out, "failed")) throw(type = "probe.stepFailed", message = arrayToList(steps, " | "));
    return out;
});

// 3b. Same, but every call is dispatched through the PUBLIC API interface's java.lang.reflect.Method,
//     never through the (hidden/non-public) agent bridge class.
apiLoader = "";
function iface(required string ifaceName) {
    return createObject("java", "java.lang.Class").forName(ifaceName, false, apiLoader);
}
function classArray(required array names) {
    var A = createObject("java", "java.lang.reflect.Array");
    var arr = A.newInstance(createObject("java", "java.lang.Class").forName("java.lang.Class"), javacast("int", arrayLen(names)));
    for (var i = 1; i <= arrayLen(names); i++) A.set(arr, javacast("int", i - 1), createObject("java", "java.lang.Class").forName(names[i]));
    return arr;
}
function objArray(required array vals) {
    var A = createObject("java", "java.lang.reflect.Array");
    var arr = A.newInstance(createObject("java", "java.lang.Class").forName("java.lang.Object"), javacast("int", arrayLen(vals)));
    for (var i = 1; i <= arrayLen(vals); i++) A.set(arr, javacast("int", i - 1), vals[i]);
    return arr;
}
function invokeVia(obj, required string ifaceName, required string method, array argTypes = [], array args = []) {
    var r = iface(ifaceName).getMethod(method, classArray(argTypes)).invoke(obj, objArray(args));
    return isNull(r) ? "" : r;
}
attempt("customSpanViaInterface", function() {
    var otel = javaClass("io.opentelemetry.api.GlobalOpenTelemetry").get();
    apiLoader = otel.getClass().getClassLoader();
    var tracer = invokeVia(otel, "io.opentelemetry.api.OpenTelemetry", "getTracer", ["java.lang.String"], ["cfml-spike"]);
    var sb = invokeVia(tracer, "io.opentelemetry.api.trace.Tracer", "spanBuilder", ["java.lang.String"], ["probe.custom.iface"]);
    var span = invokeVia(sb, "io.opentelemetry.api.trace.SpanBuilder", "startSpan");
    var out = spanIds(span);
    invokeVia(span, "io.opentelemetry.api.trace.Span", "setAttribute", ["java.lang.String", "java.lang.String"], ["probe.strategy", strategy]);
    var scope = invokeVia(span, "io.opentelemetry.context.ImplicitContextKeyed", "makeCurrent");
    try {
        out["currentAfterMakeCurrent"] = javaClass("io.opentelemetry.api.trace.Span").current().getSpanContext().getSpanId();
    } finally {
        invokeVia(scope, "io.opentelemetry.context.Scope", "close");
        invokeVia(span, "io.opentelemetry.api.trace.Span", "end");
    }
    return out;
});

// 4. cfthread with no propagation, then with manual Context propagation.
attempt("cfthreadImplicit", function() {
    var tname = "probe_" & createUUID();
    variables.probeSpanClass = javaClass("io.opentelemetry.api.trace.Span");
    thread name="#tname#" action="run" {
        thread.traceId = variables.probeSpanClass.current().getSpanContext().getTraceId();
    }
    threadJoin(tname, 10000);
    var t = cfthread[tname];
    return structKeyExists(t, "traceId") ? t.traceId : "thread status " & t.status & " " & (structKeyExists(t, "error") ? t.error.message : "");
});

attempt("cfthreadManualContext", function() {
    var tname = "probe_" & createUUID();
    variables.probeSpanClass = javaClass("io.opentelemetry.api.trace.Span");
    variables.probeCtx = javaClass("io.opentelemetry.context.Context").current();
    thread name="#tname#" action="run" {
        var scope = variables.probeCtx.makeCurrent();
        try {
            thread.traceId = variables.probeSpanClass.current().getSpanContext().getTraceId();
        } finally {
            scope.close();
        }
    }
    threadJoin(tname, 10000);
    var t = cfthread[tname];
    return structKeyExists(t, "traceId") ? t.traceId : "thread status " & t.status & " " & (structKeyExists(t, "error") ? t.error.message : "");
});

// 5. runAsync (pooled executor)
attempt("runAsync", function() {
    var Span = javaClass("io.opentelemetry.api.trace.Span");
    return runAsync(function() { return Span.current().getSpanContext().getTraceId(); }).get(10000);
});

// 6. cfhttp: does the agent inject traceparent, and does it stay in this trace with/without timeout?
// cgi.server_port reflects the Host header (the docker-mapped port); use the connector's real local port.
echoUrl = "http://127.0.0.1:" & getPageContext().getRequest().getLocalPort() & "/echo.cfm";
attempt("cfhttpNoTimeout", function() {
    cfhttp(url = echoUrl, method = "get", result = "local.r");
    return deserializeJSON(local.r.fileContent).traceparent;
});
attempt("cfhttpWithTimeout", function() {
    cfhttp(url = echoUrl, method = "get", timeout = 5, result = "local.r");
    return deserializeJSON(local.r.fileContent).traceparent;
});

// Verdict
function traceOf(key, sub) {
    if (!structKeyExists(result, key) || !result[key].ok) return "";
    var v = result[key].value;
    if (isStruct(v)) return structKeyExists(v, sub) ? v[sub] : "";
    return listLen(v, "-") == 4 ? listGetAt(v, 2, "-") : v;
}
verdict = [:];
verdict["apiVisible"] = result.globalOpenTelemetry.ok;
verdict["bridgedToAgent"] = result.globalOpenTelemetry.ok && findNoCase("javaagent", result.globalOpenTelemetry.value.otelClass & result.globalOpenTelemetry.value.tracerProviderClass) > 0;
for (k in ["currentSpan", "customSpan", "customSpanViaInterface"]) verdict[k & "InIncomingTrace"] = len(incomingTraceId) && traceOf(k, "traceId") == incomingTraceId;
for (k in ["cfthreadImplicit", "cfthreadManualContext", "runAsync", "cfhttpNoTimeout", "cfhttpWithTimeout"]) verdict[k & "InIncomingTrace"] = len(incomingTraceId) && traceOf(k, "") == incomingTraceId;
result["verdict"] = verdict;

cfcontent(type = "application/json", reset = true);
writeOutput(serializeJSON(result));
</cfscript>
