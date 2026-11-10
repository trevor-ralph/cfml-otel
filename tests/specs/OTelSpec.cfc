/**
 * Unit specs for models/OTel.cfc, Span.cfc and Instrument.cfc: the CFML logic, without Tempo/Loki/Prometheus.
 * Runs on every engine, with the javaagent or (CFMLOTEL_SDK_FALLBACK=true) cfml-otel's own SDK. Specs that need
 * spans to be recorded are skipped if neither is active.
 */
component extends="testbox.system.BaseSpec" {

    function newOTel(struct config = {}) {
        var cfg = { "tracerName": "cfml-otel-specs", "logDiagnostics": false,
            "sdkFallback": (createObject("java", "java.lang.System").getenv("CFMLOTEL_SDK_FALLBACK") ?: "") == "true" };
        structAppend(cfg, arguments.config, true);
        var o = new cfmlotel.models.OTel(cfg);
        arrayAppend(variables.created, o);
        return o;
    }

    // Bundle lifecycle: flush and (sdkFallback) shut down every instance the specs created
    function afterAll() {
        for (var o in variables.created) o.shutdown();
    }

    function run() {
        variables.created = [];
        variables.otel = newOTel();
        var active = variables.otel.status().active;

        describe("a disabled instance", function() {
            beforeEach(function() { variables.off = newOTel({ "enabled": false }); });

            it("runs span() bodies and returns their result", function() {
                expect(variables.off.span("x", function(s) { s.setAttribute("a", 1).addEvent("e"); return 7; })).toBe(7);
            });
            it("reports itself as disabled with no IDs", function() {
                var s = variables.off.status();
                expect(s.enabled).toBeFalse();
                expect(s.mode).toBe("off");
                expect(s.reason).toInclude("disabled");
                expect(variables.off.traceId()).toBe("");
                expect(variables.off.spanId()).toBe("");
                expect(variables.off.traceparent()).toBe("");
            });
            it("accepts metrics and logs without doing anything", function() {
                variables.off.counter("c").add(1);
                variables.off.histogram("h").record(1.5);
                variables.off.logInfo("never");
                expect(variables.off.onRequestEnd()).toBe(0);
            });
            it("returns headers unchanged and still runs httpSpan()", function() {
                expect(variables.off.injectHeaders({ "x-a": "1" })).toBe({ "x-a": "1" });
                expect(variables.off.httpSpan("http://h.test/", function(h, s) { return structCount(h); })).toBe(0);
            });
        });

        describe("a bridge that can't load", function() {
            it("disables itself and says why", function() {
                var broken = newOTel({ "bridgeClass": "cfmlotel.bridge.DoesNotExist" });
                var s = broken.status();
                expect(s.enabled).toBeFalse();
                expect(s.warnings[1].code).toBe("BRIDGE_NOT_LOADED");
                expect(broken.span("x", function() { return "still runs"; })).toBe("still runs");
            });
        });

        describe("status()", function() {
            it("reports the startup check", function() {
                var s = variables.otel.status();
                for (var k in ["enabled", "active", "mode", "httpMode", "apiVersion", "bridgeVersion", "warnings", "jvmAgents", "otherAgents"]) {
                    expect(s).toHaveKey(k);
                }
                expect(s.enabled).toBeTrue();
                expect(listFind("agent,sdk,other,noop", s.mode)).toBeGT(0);
                expect(s.warnings).toBeArray();
                expect(s.apiVersion).toMatch("^\d+\.\d+\.\d+");
            });
        });

        describe("span()", function() {
            it("returns the body's result, or nothing", function() {
                expect(variables.otel.span("r", function() { return { "a": 1 }; })).toBe({ "a": 1 });
                expect(isNull(variables.otel.span("n", function() {}))).toBeTrue();
            });
            it("rethrows the original exception type", function() {
                expect(function() {
                    variables.otel.span("f", function() { throw(type = "Spec.Original", message = "boom"); });
                }).toThrow("Spec.Original");
            });
            it("makes the span current inside and restores the parent after", function() {
                var before = variables.otel.spanId();
                var inside = variables.otel.span("c", function(s) { return [variables.otel.spanId(), s.getSpanId()]; });
                expect(inside[1]).toBe(inside[2]);
                expect(len(inside[1])).toBe(16);
                expect(variables.otel.spanId()).toBe(before);
            }, [], !active);
            it("nests children under the current span, in the same trace", function() {
                var ids = variables.otel.span("outer", function(o) {
                    return variables.otel.span("inner", function(i) { return [o.getTraceId(), i.getTraceId(), o.getSpanId(), i.getSpanId()]; });
                });
                expect(ids[1]).toBe(ids[2]);
                expect(ids[3]).notToBe(ids[4]);
            }, [], !active);
            it("starts a new trace with parent root", function() {
                var ids = variables.otel.span("wrap", function(w) {
                    return [w.getTraceId(), variables.otel.span("r", function(s) { return s.getTraceId(); }, { "parent": "root" })];
                });
                expect(len(ids[2])).toBe(32);
                expect(ids[2]).notToBe(ids[1]);
            }, [], !active);
        });

        describe("scopes", function() {
            it("refuses a token that isn't open on this thread", function() {
                expect(function() { variables.otel.closeScope(createUUID()); }).toThrow("cfmlotel.ScopeNotOpenOnThisThread");
            }, [], !active);
            it("closes scopes opened after a token first (innermost-first)", function() {
                var before = variables.otel.spanId();
                var a = variables.otel.startSpan("a");
                var ta = a.makeCurrent();
                var b = variables.otel.startSpan("b");
                b.makeCurrent();
                variables.otel.closeScope(ta);
                expect(variables.otel.spanId()).toBe(before);
                b.end();
                a.end();
            }, [], !active);
            it("closeLeakedScopes() closes what was left open and counts it", function() {
                var before = variables.otel.spanId();
                var s = variables.otel.startSpan("leak");
                s.makeCurrent();
                s.end();
                expect(variables.otel.closeLeakedScopes()).toBe(1);
                expect(variables.otel.spanId()).toBe(before);
                expect(variables.otel.closeLeakedScopes()).toBe(0);
            }, [], !active);
            it("a scope a span() body leaked doesn't outlive the span()", function() {
                var before = variables.otel.spanId();
                variables.otel.span("outer", function() {
                    var l = variables.otel.startSpan("leaked");
                    l.makeCurrent();
                    l.end();
                });
                expect(variables.otel.spanId()).toBe(before);
            }, [], !active);
        });

        describe("propagation", function() {
            it("injectHeaders() adds traceparent for the current span and keeps other headers", function() {
                var h = variables.otel.span("p", function(s) {
                    var r = variables.otel.injectHeaders({ "x-keep": "yes" });
                    r["spanId"] = s.getSpanId();
                    return r;
                });
                expect(h["x-keep"]).toBe("yes");
                expect(listGetAt(h.traceparent, 3, "-")).toBe(h.spanId);
            }, [], !active);
            it("extractContext() continues a remote trace, matching header names case-insensitively", function() {
                var tid = "4bf92f3577b34da6a3ce929d0e0e4736";
                var ctx = variables.otel.extractContext({ "TraceParent": "00-#tid#-00f067aa0ba902b7-01" });
                expect(variables.otel.span("child", function(s) { return s.getTraceId(); }, { "parent": ctx })).toBe(tid);
            }, [], !active);
            it("bindContext() carries the context into a cfthread", function() {
                var expected = variables.otel.span("t", function() {
                    variables.bound = variables.otel.bindContext(function() { return variables.otel.traceId(); });
                    return variables.otel.traceId();
                });
                var tn = "spec" & left(replace(createUUID(), "-", "", "all"), 12);
                thread name="#tn#" { thread.r = variables.bound(); }
                threadJoin(tn, 10000);
                expect(cfthread[tn].r).toBe(expected);
            }, [], !active);
        });

        describe("httpSpan() / http()", function() {
            it("hands the body the trace headers and returns its result", function() {
                var r = variables.otel.span("h", function() {
                    return variables.otel.httpSpan("http://127.0.0.1:1/x", function(headers, span) { return { "headers": headers, "statusCode": "200 OK" }; });
                });
                expect(r.headers).toHaveKey("traceparent");
                expect(r.statusCode).toBe("200 OK");
            }, [], !active);
            it("http() returns the cfhttp result, also on a connection failure", function() {
                var r = variables.otel.http("http://127.0.0.1:1/unreachable", { "timeout": 3 });
                expect(r).toHaveKey("statusCode");
                expect(left(r.statusCode, 3)).notToMatch("^\d{3}$");
            });
            it("still runs the body when the span can't be set up", function() {
                // a port no URL parser accepts, and options the helper can't use: the call itself must go ahead
                expect(variables.otel.httpSpan("http://h.test:99999999999/x", function() { return "ran"; })).toBe("ran");
                expect(variables.otel.httpSpan("http://h.test/", function() { return "ran"; }, { "attributes": "not a struct" })).toBe("ran");
            });
            it("rethrows what the body throws", function() {
                expect(function() {
                    variables.otel.httpSpan("http://h.test/", function() { throw(type = "Spec.HttpFail"); });
                }).toThrow("Spec.HttpFail");
            });
        });

        describe("conversions and instruments", function() {
            it("_toCfml() turns nested Java maps and lists into structs and arrays", function() {
                var m = createObject("java", "java.util.HashMap").init();
                var l = createObject("java", "java.util.ArrayList").init();
                l.add("x");
                m.put("list", l);
                m.put("n", javaCast("int", 3));
                var c = variables.otel._toCfml(m);
                expect(c).toBeStruct();
                expect(c.list).toBeArray();
                expect(c.list[1]).toBe("x");
                expect(c.n).toBe(3);
            });
            it("long instruments round fractions; double instruments keep them", function() {
                expect(variables.otel.counter("spec.rounded")._value(0.7)).toBe(1);
                expect(variables.otel.counter("spec.rounded")._value(2.4)).toBe(2);
                expect(variables.otel.histogram("spec.latency")._value(0.7)).toBe(0.7);
            });
            it("caches instruments by name", function() {
                // identity, not toBe(): a deep comparison would try to copy the bridge, which has no constructor
                var jSystem = createObject("java", "java.lang.System");
                expect(jSystem.identityHashCode(variables.otel.counter("spec.cached")))
                    .toBe(jSystem.identityHashCode(variables.otel.counter("spec.cached")));
            });
        });
    }
}
