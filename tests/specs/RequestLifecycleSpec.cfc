/**
 * Unit specs for the ColdBox interceptor (interceptors/RequestLifecycle.cfc) with fakes for OTel, the ColdBox
 * controller and the event: the branches the ColdBox integration app can't reach in one configuration (an app
 * without an exceptionHandler; tests/coldbox has one). Runs on every engine.
 */
component extends="testbox.system.BaseSpec" {

    /** A fake OTel that records the calls the interceptor makes. */
    function fakeOTel() {
        variables.calls = [];
        return {
            "onError": function(exception, statusCode = 0, endRequest = true) {
                arrayAppend(variables.calls, { "m": "onError", "type": arguments.exception.type,
                    "statusCode": arguments.statusCode, "endRequest": arguments.endRequest });
            },
            "onRequestEnd": function() { arrayAppend(variables.calls, { "m": "onRequestEnd" }); return 0; },
            "onRequestStart": function() { arrayAppend(variables.calls, { "m": "onRequestStart" }); },
            "_setRoute": function(route, framework = false) {
                arrayAppend(variables.calls, { "m": "_setRoute", "route": arguments.route, "framework": arguments.framework });
                return true;
            },
            "hasServerSpan": function() { return false; }
        };
    }

    /** The interceptor with the fakes in place of what WireBox injects. */
    function newInterceptor(string exceptionHandler = "", struct settings = {}) {
        var handler = arguments.exceptionHandler;
        var cfg = { "traceEvents": false, "setRoute": true };
        structAppend(cfg, arguments.settings, true);
        var ic = prepareMock(createObject("component", "cfmlotel.interceptors.RequestLifecycle"));
        ic.$property("otel", "variables", fakeOTel());
        ic.$property("settings", "variables", cfg);
        ic.$property("cbController", "variables", { "getSetting": function(name, defaultValue = "") { return handler; } });
        return ic;
    }

    function anException() {
        try {
            throw(type = "Custom.SpecFail", message = "spec failure");
        } catch (any e) {
            return e;
        }
    }

    function fakeEvent(string route = "", string eventName = "main.index") {
        var r = arguments.route;
        var ev = arguments.eventName;
        return {
            "getCurrentRoute": function() { return r; },
            "getCurrentEvent": function() { return ev; },
            "getCurrentRoutedURL": function() { return ""; }
        };
    }

    function run() {
        describe("the ColdBox interceptor", function() {
            afterEach(function() { structDelete(request, "__cfmlotelExceptionHandler"); });

            it("without an exceptionHandler, ends the request as a 500 at onException", function() {
                var ic = newInterceptor("");
                ic.onException(event = fakeEvent(), data = { "exception": anException() }, rc = {}, prc = {});
                expect(variables.calls).toHaveLength(1);
                expect(variables.calls[1].m).toBe("onError");
                expect(variables.calls[1].type).toBe("Custom.SpecFail");
                expect(variables.calls[1].statusCode).toBe(500);
                expect(variables.calls[1].endRequest).toBeTrue();
                expect(structKeyExists(request, "__cfmlotelExceptionHandler")).toBeFalse();
            });

            it("with an exceptionHandler, records the exception and ends the request after that handler", function() {
                var ic = newInterceptor("main.onAppError");
                ic.onException(event = fakeEvent(), data = { "exception": anException() }, rc = {}, prc = {});
                expect(variables.calls).toHaveLength(1);
                expect(variables.calls[1].m).toBe("onError");
                expect(variables.calls[1].statusCode).toBe(0);
                expect(variables.calls[1].endRequest).toBeFalse();

                // another event finishing first (a viewlet inside the handler, say) doesn't end the request
                ic.postEvent(event = fakeEvent(), data = { "processedEvent": "main.sidebar" }, rc = {}, prc = {});
                expect(variables.calls).toHaveLength(1);

                ic.postEvent(event = fakeEvent(), data = { "processedEvent": "main.onAppError" }, rc = {}, prc = {});
                expect(variables.calls).toHaveLength(2);
                expect(variables.calls[2].m).toBe("onRequestEnd");

                // once only
                ic.postEvent(event = fakeEvent(), data = { "processedEvent": "main.onAppError" }, rc = {}, prc = {});
                expect(variables.calls).toHaveLength(2);
            });

            it("ignores postEvent when no exception is pending", function() {
                var ic = newInterceptor("main.onAppError");
                ic.postEvent(event = fakeEvent(), data = { "processedEvent": "main.onAppError" }, rc = {}, prc = {});
                expect(variables.calls).toHaveLength(0);
            });

            it("names the request by its route pattern, as a framework route", function() {
                var ic = newInterceptor();
                ic.preProcess(event = fakeEvent("api/users/:id/"), data = {}, rc = {}, prc = {});
                var routes = variables.calls.filter(function(c) { return c.m == "_setRoute"; });
                expect(routes).toHaveLength(1);
                expect(routes[1].route).toBe("/api/users/:id/");
                expect(routes[1].framework).toBeTrue();
            });

            it("names the request by its event without a route or on the :handler/:action? convention route", function() {
                for (var pattern in ["", ":handler/:action?"]) {
                    var ic = newInterceptor();
                    ic.preProcess(event = fakeEvent(pattern, "orders.checkout"), data = {}, rc = {}, prc = {});
                    var routes = variables.calls.filter(function(c) { return c.m == "_setRoute"; });
                    expect(routes[1].route).toBe("orders.checkout", "pattern [#pattern#]");
                }
            });

            it("leaves the name alone with setRoute: false", function() {
                var ic = newInterceptor("", { "setRoute": false });
                ic.preProcess(event = fakeEvent("api/users/:id/"), data = {}, rc = {}, prc = {});
                expect(variables.calls.filter(function(c) { return c.m == "_setRoute"; })).toHaveLength(0);
            });
        });
    }
}
