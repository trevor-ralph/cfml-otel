<cfscript>
/*
 * Integration scenarios. Called with a known traceparent; returns JSON that the pytest runner (tests/integration)
 * cross-checks against Tempo / Prometheus / Loki.
 */
setting showdebugoutput=false requesttimeout=60;
otel = application.otel;
hdrs = getHttpRequestData().headers;
out = [:];
out["engine"] = structKeyExists(server, "lucee") ? "Lucee " & server.lucee.version : server.coldfusion.productname & " " & server.coldfusion.productversion;
out["status"] = otel.status();
out["incomingTraceparent"] = structKeyExists(hdrs, "traceparent") ? hdrs.traceparent : "";
out["traceId"] = otel.traceId();
out["serverSpanId"] = otel.spanId();
out["scenarios"] = [:];

function scenario(required string name, required any fn) {
    try {
        var v = arguments.fn();
        out.scenarios[arguments.name] = { "ok": true, "value": isNull(v) ? "" : v };
    } catch (any e) {
        out.scenarios[arguments.name] = { "ok": false, "error": e.type & ": " & e.message & " " & e.detail };
    }
}

function hex(required numeric chars) {
    var s = "";
    while (len(s) < arguments.chars) s &= lCase(replace(createUUID(), "-", "", "all"));
    return left(s, arguments.chars);
}

// Nested spans, attribute typing, return values
scenario("nested", function() {
    var r = {};
    r["returned"] = otel.span("s2.outer", function(s) {
        s.setAttributes({ "t.str": "x", "t.num": 42, "t.dbl": 1.5, "t.bool": true, "t.arr": ["a", "b"], "t.nums": [1, 2, 3] });
        r["outerSpanId"] = s.getSpanId();
        otel.span("s2.inner", function(c) {
            r["innerSpanId"] = c.getSpanId();
            r["currentInInner"] = otel.spanId();
            r["innerTraceId"] = otel.traceId();
        });
        return "ret";
    });
    r["currentAfter"] = otel.spanId();
    return r;
});

// Exception inside span(): recorded, status ERROR, rethrown with original type
scenario("exception", function() {
    var r = { "thrown": false };
    try {
        otel.span("s3.fails", function(s) {
            r["spanId"] = s.getSpanId();
            throw(type = "Custom.Fail", message = "boom");
        });
    } catch (Custom.Fail e) {
        r["thrown"] = true;
        r["type"] = e.type;
    }
    r["currentAfter"] = otel.spanId();
    return r;
});

// Java exception passed to recordException
scenario("javaException", function() {
    var r = {};
    try {
        createObject("java", "java.lang.Integer").parseInt("not-a-number");
    } catch (any e) {
        otel.span("s14.java-exception", function(s) { r["spanId"] = s.getSpanId(); s.recordException(e).setStatus("ERROR", "parse failed"); });
    }
    return r;
});

// cfthread: unbound (baseline: context is lost) vs bindContext()
scenario("cfthreadUnbound", function() {
    var tn = "u" & hex(12);
    thread name="#tn#" action="run" {
        thread.traceId = application.otel.traceId();
    }
    threadJoin(tn, 10000);
    return structKeyExists(cfthread[tn], "traceId") ? cfthread[tn].traceId : "status=" & cfthread[tn].status;
});

scenario("cfthreadBound", function() {
    variables.boundFn = otel.bindContext(function() {
        return otel.span("s4.in-thread", function(s) {
            return { "traceId": otel.traceId(), "spanId": s.getSpanId() };
        });
    });
    var tn = "b" & hex(12);
    thread name="#tn#" action="run" {
        thread.result = variables.boundFn();
    }
    threadJoin(tn, 10000);
    var t = cfthread[tn];
    if (structKeyExists(t, "result")) return t.result;
    throw(type = "scenario.thread", message = "thread #t.status#", detail = structKeyExists(t, "error") ? t.error.message : "");
});

// runAsync (agent propagates through executors on its own)
scenario("runAsync", function() {
    return runAsync(function() {
        return otel.span("s5.async", function(s) { return { "traceId": otel.traceId(), "spanId": s.getSpanId() }; });
    }).get(10000);
});

// Manual startSpan + makeCurrent + closeScope
scenario("manual", function() {
    var r = {};
    var s = otel.startSpan("s6.manual", { "attributes": { "t.manual": true } });
    r["spanId"] = s.getSpanId();
    var tok = s.makeCurrent();
    try {
        otel.span("s6.child", function(c) { r["childSpanId"] = c.getSpanId(); });
        r["currentInside"] = otel.spanId();
    } finally {
        otel.closeScope(tok);
        s.end();
    }
    r["currentAfter"] = otel.spanId();
    return r;
});

// Outbound propagation: explicit CLIENT span + injected headers on cfhttp
scenario("cfhttp", function() {
    var echoUrl = "http://127.0.0.1:" & getPageContext().getRequest().getLocalPort() & getDirectoryFromPath(cgi.script_name) & "echo.cfm";
    return otel.span("s7.client", function(s) {
        var h = otel.injectHeaders();
        cfhttp(url = echoUrl, method = "get", result = "local.res", timeout = 10) {
            for (var k in h) cfhttpparam(type = "header", name = k, value = h[k]);
        }
        return { "spanId": s.getSpanId(), "sent": h.traceparent, "received": deserializeJSON(local.res.fileContent).traceparent };
    }, { "kind": "client" });
});

// Inbound propagation: extractContext() from custom headers (e.g. a queue message)
scenario("extract", function() {
    var R = hex(32);
    var P = hex(16);
    var ctx = otel.extractContext({ "TraceParent": "00-#R#-#P#-01" });
    return otel.span("s8.remote-parent", function(s) {
        return { "traceId": otel.traceId(), "spanId": s.getSpanId(), "expectTraceId": R, "expectParentId": P };
    }, { "parent": ctx, "kind": "consumer" });
});

// Root span: starts a new trace
scenario("root", function() {
    return otel.span("s9.root", function(s) { return otel.traceId(); }, { "parent": "root" });
});

// Metrics
scenario("metrics", function() {
    otel.counter("cfmlotel.test.calls", "test counter").add(1, { "scenario": "metrics" });
    otel.histogram("cfmlotel.test.latency", "test histogram", "ms").record(12.5, { "scenario": "metrics" });
    otel.gauge("cfmlotel.test.level", "test gauge").set(7);
    otel.upDownCounter("cfmlotel.test.inflight", "test up-down counter").add(3).add(-1);
    // long instrument + fractional value: rounded (0.7 -> 1), never truncated to 0
    var rounded = otel.counter("cfmlotel.test.rounded", "long counter given fractions");
    return { "rounded": rounded._value(0.7), "whole": rounded._value(3), "double": otel.histogram("cfmlotel.test.latency")._value(0.7) };
});

// Logs correlated with the current trace
scenario("logs", function() {
    var marker = "m" & hex(16);
    otel.logInfo("s11 hello #marker#", { "scenario": "logs" });
    otel.logError("s11 failure #marker#");
    return { "marker": marker, "traceId": otel.traceId() };
});

// Disabled instance is a safe no-op
scenario("disabled", function() {
    var off = new cfmlotel.models.OTel({ "enabled": false });
    var v = off.span("never", function(s) { s.setAttribute("a", 1).addEvent("e"); return 5; });
    off.counter("never").add(1);
    off.logInfo("never");
    return { "value": v, "enabled": off.status().enabled, "traceId": off.traceId() };
});

// currentSpan().end() must not end the agent's SERVER span
scenario("borrowedEnd", function() {
    otel.currentSpan().end();
    return otel.span("s15.after-borrowed-end", function(s) { return s.getSpanId(); });
});

// A scope leaked inside span() must not survive it: closing the outer scope closes the inner first
scenario("leakInsideSpan", function() {
    var r = {};
    otel.span("s16.outer", function(s) {
        var leaked = otel.startSpan("s16.leaked");
        leaked.makeCurrent();
        leaked.end();
    });
    r["currentAfterSpan"] = otel.spanId();
    // Manual tokens closed in the wrong order (outer first)
    var a = otel.startSpan("s16.a");
    var ta = a.makeCurrent();
    var b = otel.startSpan("s16.b");
    var tb = b.makeCurrent();
    otel.closeScope(ta);
    r["currentAfterOuterClose"] = otel.spanId();
    b.end();
    a.end();
    r["leftOpen"] = otel.onRequestEnd();
    return r;
});

// fn closes span()'s / runInContext()'s own scope (here via onRequestEnd()): no library error, and
// fn's return value or its original exception still reaches the caller
scenario("scopeClosedEarly", function() {
    var r = {};
    r["spanValue"] = otel.span("s17.closed-early", function() { otel.onRequestEnd(); return "value"; });
    r["contextValue"] = otel.runInContext(otel.captureContext(), function() { otel.onRequestEnd(); return "ctx"; });
    try {
        otel.span("s17.closed-early-fails", function() {
            otel.onRequestEnd();
            throw(type = "Custom.Original", message = "original");
        });
        r["thrownType"] = "none";
    } catch (any e) {
        r["thrownType"] = e.type;
    }
    r["currentAfter"] = otel.spanId();
    return r;
});

// cfquery / queryExecute against SQL Server: the agent's JDBC instrumentation creates CLIENT spans for each
// statement, nested under the cfml-otel span that is current when the query runs. Skipped with ?db=0 (no
// SQL Server container, e.g. on ARM).
if (!structKeyExists(url, "db") || url.db != 0) {
    scenario("cfquery", function() {
        return otel.span("s18.db", function(s) {
            var ds = { "datasource": "cfmlotel_mssql" };
            queryExecute("IF OBJECT_ID('dbo.cfmlotel_items') IS NULL CREATE TABLE dbo.cfmlotel_items (id INT PRIMARY KEY, name NVARCHAR(50))", {}, ds);
            queryExecute("MERGE INTO dbo.cfmlotel_items AS t USING (SELECT 1 AS id, N'first' AS name) AS s ON t.id = s.id
                WHEN NOT MATCHED THEN INSERT (id, name) VALUES (s.id, s.name);", {}, ds);
            var q = queryExecute("SELECT name FROM dbo.cfmlotel_items WHERE id = :id",
                { "id": { "value": 1, "cfsqltype": "cf_sql_integer" } }, ds);
            return { "spanId": s.getSpanId(), "rows": q.recordCount, "name": q.name[1] };
        });
    });

    // ACF only: the same query through Microsoft's JDBC driver as an "Other" datasource, the workaround for
    // the built-in driver's jdbc:macromedia: URLs that the agent can't parse
    if (!structKeyExists(server, "lucee")) {
        scenario("cfqueryMsDriver", function() {
            return otel.span("s19.db-msdriver", function(s) {
                var q = queryExecute("SELECT name FROM dbo.cfmlotel_items WHERE id = :id",
                    { "id": { "value": 1, "cfsqltype": "cf_sql_integer" } }, { "datasource": "cfmlotel_mssql_msdriver" });
                return { "spanId": s.getSpanId(), "rows": q.recordCount, "name": q.name[1] };
            });
        });
    }
}

cfcontent(type = "application/json", reset = true);
writeOutput(serializeJSON(out));
</cfscript>
