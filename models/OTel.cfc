/**
 * cfml-otel facade. Create ONE instance per application (application scope or a WireBox singleton).
 *
 * With the OpenTelemetry javaagent attached, everything here flows into the agent's SDK: spans nest
 * under the agent's HTTP SERVER span, and metrics/logs use the agent's exporters. Without the agent
 * (or if the jars can't be loaded) every method is a safe no-op.
 *
 * The OTel API jars and the bridge jar in /lib must be on the application's classpath, e.g.
 *   this.javaSettings = { loadPaths: [ "/path/to/cfml-otel/lib/" ] };
 *
 * IMPLEMENTATION NOTE: all state lives in this.__state and internal calls go through this.*, never
 * the variables scope. On Adobe ColdFusion 2025, when a CFC method is invoked from a closure that was
 * itself passed into a CFC method, on a cfthread/runAsync thread, `variables` resolves to the
 * calling PAGE's variables scope (only `this` stays correct). Spans are routinely used exactly that
 * way, so this component must not depend on `variables` at all.
 */
component {

    public function init(struct config = {}) {
        var cfg = {
            "enabled": true,
            "tracerName": "cfml-otel",
            "tracerVersion": "",
            "meterName": "",          // defaults to tracerName
            "loggerName": "",         // defaults to tracerName
            "logLeakedScopes": true,  // writeLog() when onRequestEnd() has to close scopes the app leaked
            "logDiagnostics": true,   // writeLog() the startup check's warnings (also in status().warnings)
            // httpSpan() / http(): "auto" creates CLIENT spans unless the agent already traces cfhttp correctly
            // (ACF with its HttpClient instrumentation on); "always" / "never" force it either way
            "cfhttpSpans": "auto",
            // No javaagent attached and nothing else registered: start cfml-otel's own SDK (needs lib/sdk/ in
            // loadPaths). Configured by the standard OTEL_* env vars; you must call onRequestStart()/onRequestEnd().
            "sdkFallback": false,
            "serviceName": "",        // fallback only: this app's service.name; wins over OTEL_SERVICE_NAME (default: app name)
            "bridgeClass": "cfmlotel.bridge.OtelBridge"
        };
        structAppend(cfg, arguments.config, true);

        this.__state = {
            "config": cfg,
            "instruments": {},
            "enabled": false,
            "agentBridged": false,
            "active": false,
            "reason": "",
            "bridgeVersion": "",
            "diagnostics": { "warnings": [] },
            "httpMode": "off",        // span: httpSpan() creates the CLIENT span | agent: the agent does | off
            "mode": "off",            // agent | sdk (fallback) | other (another implementation) | noop | off
            "sdk": {}                 // the fallback's start result, when requested
        };
        var st = this.__state;
        // Class handle used on every scope open/close; looked up once instead of per span
        st.jThread = createObject("java", "java.lang.Thread");
        // Resolve sibling components by full dotted path: relative `new Span()` can resolve against the
        // wrong template under the ACF thread bug described above.
        var myName = getMetadata(this).name;
        st.pkg = listLen(myName, ".") > 1 ? listDeleteAt(myName, listLen(myName, "."), ".") & "." : "";
        // The span handed out when there is nothing to record. It keeps no state, so one serves every caller.
        st.noopSpan = createObject("component", st.pkg & "Span").init(this, "", "", false, false);
        // Set once the app's onAbort() has called onAbort(): see onRedirecting()
        st.abortHookSeen = false;

        if (!cfg.enabled) {
            st.reason = "disabled by configuration";
            return this;
        }
        try {
            st.bridge = createObject("java", cfg.bridgeClass);
            // The OpenTelemetry this instance reports through: the global one (the agent's, or a no-op), or with
            // sdkFallback an SDK of its own, never shared with another application
            st.otel = st.bridge.openTelemetry();
            if (cfg.sdkFallback) {
                if (!st.bridge.isActive() && !st.bridge.isAgentAttached()) {
                    var started = st.bridge.startSdkFallback({ "otel.service.name": this._defaultServiceName() },
                        len(cfg.serviceName) ? { "otel.service.name": cfg.serviceName } : {});
                    if (started.get("started")) st.otel = started.get("sdk");
                    st.sdk = { "started": started.get("started"), "serviceName": started.get("serviceName"), "error": started.get("error") };
                } else {
                    st.sdk = { "started": false, "serviceName": "", "error": "", "notNeeded": true };
                }
            }
            var isSdk = structKeyExists(st.sdk, "started") && st.sdk.started;
            var meterName = len(cfg.meterName) ? cfg.meterName : cfg.tracerName;
            var loggerName = len(cfg.loggerName) ? cfg.loggerName : cfg.tracerName;
            st.tracer = st.bridge.tracer(st.otel, cfg.tracerName, cfg.tracerVersion);
            st.meter = st.bridge.meter(st.otel, meterName, cfg.tracerVersion);
            st.logger = st.bridge.logger(st.otel, loggerName);
            st.bridgeVersion = st.bridge.version();
            st.agentBridged = st.bridge.isAgentBridged();
            st.active = st.bridge.isActiveFor(st.otel);
            st.enabled = true;
            st.mode = isSdk ? "sdk" : (st.agentBridged ? "agent" : (st.active ? "other" : "noop"));
            if (!st.active) st.reason = "OpenTelemetry API loaded but no SDK/agent is active (no-op)";
        } catch (any e) {
            st.reason = "could not load #cfg.bridgeClass# (are cfml-otel/lib jars in this.javaSettings.loadPaths?): " & e.message;
            st.diagnostics.warnings = [{ "level": "warn", "code": "BRIDGE_NOT_LOADED",
                "message": "cfml-otel is a no-op: " & st.reason }];
        }
        if (st.enabled) {
            try {
                var isLucee = structKeyExists(server, "lucee");
                if (cfg.cfhttpSpans == "always") st.httpMode = "span";
                else if (cfg.cfhttpSpans == "never") st.httpMode = "agent";
                else st.httpMode = (!isLucee && st.mode == "agent" && st.bridge.agentTracesHttpClient()) ? "agent" : "span";
            } catch (any e) {
                st.httpMode = "span";
            }
            try {
                st.diagnostics = this._toCfml(st.bridge.diagnostics(structKeyExists(server, "lucee") ? "lucee" : "acf",
                    st.otel, st.mode == "sdk"));
                if (!st.active && arrayLen(st.diagnostics.warnings)) st.reason = st.diagnostics.warnings[1].message;
            } catch (any e) {
                st.diagnostics = { "warnings": [{ "level": "warn", "code": "DIAGNOSTICS_FAILED",
                    "message": "cfml-otel's startup check failed: " & e.message }] };
            }
            if (structKeyExists(st.sdk, "started") && !st.sdk.started && len(st.sdk.error)) {
                // the no-agent warning is moot once the fallback was requested; this one says what happened
                var failed = { "level": "warn", "code": "SDK_FALLBACK_FAILED",
                    "message": "sdkFallback is on, but cfml-otel's SDK didn't start, so cfml-otel is a no-op: " & st.sdk.error };
                st.reason = failed.message;
                st.diagnostics.warnings = st.diagnostics.warnings.filter(function(w) { return w.code != "NO_OTEL_AGENT"; });
                arrayPrepend(st.diagnostics.warnings, failed);
            }
        }
        if (cfg.logDiagnostics) {
            for (var w in st.diagnostics.warnings) {
                writeLog(type = w.level == "info" ? "information" : "warning", file = "cfml-otel",
                    text = "cfml-otel [#w.code#] #w.message#");
            }
        }
        return this;
    }

    /** @hint internal: service.name for the fallback SDK when OTEL_SERVICE_NAME isn't set */
    public string function _defaultServiceName() {
        if (len(this.__state.config.serviceName)) return this.__state.config.serviceName;
        try {
            if (len(application.applicationName)) return application.applicationName;
        } catch (any ignored) {}
        return "cfml-app";
    }

    /** @hint internal: Java Map/List from the bridge -> CFML struct/array (stable serializeJSON on both engines) */
    public any function _toCfml(required any v) {
        if (isInstanceOf(arguments.v, "java.util.Map")) {
            var s = [:];
            var it = arguments.v.entrySet().iterator();
            while (it.hasNext()) {
                var e = it.next();
                s[e.getKey()] = this._toCfml(e.getValue());
            }
            return s;
        }
        if (isInstanceOf(arguments.v, "java.util.List")) {
            var a = [];
            var it2 = arguments.v.iterator();
            while (it2.hasNext()) arrayAppend(a, this._toCfml(it2.next()));
            return a;
        }
        return arguments.v;
    }

    // ------------------------------------------------------------------------------------------
    // Status
    // ------------------------------------------------------------------------------------------

    public boolean function isEnabled() {
        return this.__state.enabled;
    }

    /**
     * What cfml-otel found at startup. warnings: array of { level (warn|info), code, message }, e.g.
     * NO_OTEL_AGENT, AGENT_NOT_BRIDGED, OTHER_APM_AGENT, LUCEE_HTTPCLIENT_INSTRUMENTATION (see README).
     */
    public struct function status() {
        var st = this.__state;
        var d = st.diagnostics;
        var s = [:];
        s["enabled"] = st.enabled;
        s["active"] = st.active;
        s["agentBridged"] = st.agentBridged;
        s["implementation"] = st.enabled ? st.bridge.implementationOf(st.otel) : "";
        s["reason"] = st.reason;
        s["bridgeVersion"] = st.bridgeVersion;
        for (var k in ["apiVersion", "agentPresent", "agentVersion", "agentPath", "testedAgentVersion", "otherAgents", "jvmAgents"]) {
            if (structKeyExists(d, k)) s[k] = d[k];
        }
        s["warnings"] = duplicate(d.warnings);
        s["httpMode"] = st.httpMode;
        s["mode"] = st.mode;
        s["sdkFallback"] = duplicate(st.sdk);
        // fallback SDKs running in this class loader (one per OTel instance that started one and wasn't shut down)
        if (structKeyExists(st.sdk, "started") && st.enabled) s.sdkFallback["runningInClassLoader"] = st.bridge.sdkFallbackCount();
        return s;
    }

    // ------------------------------------------------------------------------------------------
    // Request lifecycle without the agent (sdkFallback): cfml-otel creates the HTTP SERVER span itself.
    // With the agent these are no-ops apart from scope cleanup, so call them unconditionally.
    // ------------------------------------------------------------------------------------------

    /**
     * Call from Application.cfc onRequestStart(). In sdkFallback mode, starts this request's SERVER span
     * (continuing an incoming traceparent) and makes it current; otherwise does nothing.
     */
    public any function onRequestStart() {
        var st = this.__state;
        if (!st.enabled || st.mode != "sdk" || structKeyExists(request, "__cfmlotelServer")) return this;
        try {
            var req = getPageContext().getRequest();
            var carrier = {};
            for (var h in ["traceparent", "tracestate", "baggage"]) {
                var v = req.getHeader(h);
                if (!isNull(v)) carrier[h] = v;
            }
            var method = uCase(req.getMethod());
            var route = cgi.script_name;
            var attrs = [:];
            attrs["http.request.method"] = method;
            attrs["http.route"] = route;
            attrs["url.scheme"] = req.getScheme();
            attrs["url.path"] = req.getRequestURI();
            var qs = req.getQueryString();
            // signatures and access keys are redacted, as in a CLIENT span's url.full
            if (!isNull(qs) && len(qs)) attrs["url.query"] = st.bridge.redactQuery(qs);
            attrs["server.address"] = req.getServerName();
            attrs["server.port"] = req.getServerPort();
            attrs["client.address"] = req.getRemoteAddr();
            var ua = req.getHeader("User-Agent");
            if (!isNull(ua)) attrs["user_agent.original"] = ua;
            attrs["network.protocol.version"] = listLast(req.getProtocol(), "/");
            // Parent: the inbound trace headers or nothing. Never the thread's current context: a request that
            // ended without cleanup leaves its span current on the pooled thread.
            var s = this.startSpan(method & " " & route, {
                "kind": "server", "attributes": attrs, "parent": st.bridge.extractRootContext(st.otel, carrier) });
            request.__cfmlotelServer = { "span": s, "token": s.makeCurrent(), "thread": st.jThread.currentThread().getId() };
        } catch (any e) {
            // tracing must never break the request
        }
        return this;
    }

    /** @hint internal: ends the fallback SERVER span (status code from the response; 5xx = error) */
    public void function _endServerSpan() {
        if (!structKeyExists(request, "__cfmlotelServer")) return;
        var srv = request.__cfmlotelServer;
        structDelete(request, "__cfmlotelServer");
        try {
            var code = this.__state.bridge.responseStatus(getPageContext().getResponse());
            if (structKeyExists(srv, "statusCode") && srv.statusCode > 0) code = srv.statusCode;
            // after an exception, a non-error status only means the app hadn't set one yet: unknown, leave it out
            else if (structKeyExists(srv, "errorType") && code < 400) code = 0;
            // a redirect is about to set the status (onRedirecting()): what the response says now isn't it
            else if (structKeyExists(srv, "statusUnknown")) code = 0;
            if (code > 0) {
                srv.span.setAttribute("http.response.status_code", code);
                if (code >= 500) {
                    if (!structKeyExists(srv, "errorType")) srv.span.setAttribute("error.type", toString(code));
                    srv.span.setStatus("ERROR");
                }
            }
        } catch (any ignored) {
        } finally {
            srv.span.end();
        }
    }

    /**
     * Call from Application.cfc onApplicationEnd() (and before stopping an app on purpose). Flushes
     * pending telemetry and, in sdkFallback mode, shuts the SDK down once no other app uses it.
     * With the agent it does nothing: the agent flushes on JVM shutdown.
     */
    public void function shutdown() {
        var st = this.__state;
        if (!st.enabled || st.mode != "sdk") return;
        try {
            st.bridge.shutdownSdkFallback(st.otel);
        } catch (any ignored) {}
        st.mode = "noop";
        st.active = false;
    }

    // ------------------------------------------------------------------------------------------
    // Spans
    // ------------------------------------------------------------------------------------------

    /**
     * Run fn inside a new span that is current for its duration. fn receives the Span.
     * Exceptions are recorded on the span (status ERROR) and rethrown. Returns fn's result.
     *
     * options: kind (internal|server|client|producer|consumer), attributes (struct),
     *          parent (a context from captureContext()/extractContext(), or "root")
     */
    public any function span(required string name, required any fn, struct options = {}) {
        var s = this.startSpan(arguments.name, arguments.options);
        var token = s.makeCurrent();
        try {
            var result = arguments.fn(s);
            if (!isNull(result)) return result;
        } catch (any e) {
            s.recordException(e);
            s.setStatus("ERROR", e.message);
            rethrow;
        } finally {
            // fn may already have closed this scope (onRequestEnd(), or closing an enclosing token).
            // That is not an error here: throwing from finally would replace fn's result or exception.
            try {
                this._releaseScope(token);
            } finally {
                s.end();
            }
        }
    }

    /**
     * Start a span WITHOUT making it current. You must call end() on it.
     * Use span.makeCurrent() + otel.closeScope(token) if children should nest under it.
     */
    public any function startSpan(required string name, struct options = {}) {
        var st = this.__state;
        if (!st.enabled) return st.noopSpan;
        var kind =structKeyExists(arguments.options, "kind") ? arguments.options.kind : "internal";
        var attributes = structKeyExists(arguments.options, "attributes") ? arguments.options.attributes : {};
        var parent = structKeyExists(arguments.options, "parent") ? arguments.options.parent : "";
        var js = st.bridge.startSpan(st.tracer, arguments.name, kind, attributes, parent);
        return createObject("component", st.pkg & "Span").init(this, st.bridge, js, true, true);
    }

    /** The current span (usually the agent's SERVER span or an enclosing span()). end() on it is ignored. */
    public any function currentSpan() {
        var st = this.__state;
        if (!st.enabled) return st.noopSpan;
        return createObject("component", st.pkg & "Span").init(this, st.bridge, st.bridge.currentSpan(), false, true);
    }

    public any function setAttributes(required struct attributes) {
        this.currentSpan().setAttributes(arguments.attributes);
        return this;
    }

    public any function addEvent(required string name, struct attributes = {}) {
        this.currentSpan().addEvent(arguments.name, arguments.attributes);
        return this;
    }

    public any function recordException(required any error, struct attributes = {}) {
        this.currentSpan().recordException(arguments.error, arguments.attributes).setStatus("ERROR");
        return this;
    }

    public string function traceId() {
        var st = this.__state;
        return st.enabled ? st.bridge.currentTraceId() : "";
    }

    public string function spanId() {
        var st = this.__state;
        return st.enabled ? st.bridge.currentSpanId() : "";
    }

    // ------------------------------------------------------------------------------------------
    // Context: threads, async, propagation
    // ------------------------------------------------------------------------------------------

    /** Snapshot of the current context, to hand to another thread (cfthread does NOT inherit it). */
    public any function captureContext() {
        var st = this.__state;
        return st.enabled ? st.bridge.currentContext() : "";
    }

    /** Run fn with ctx (from captureContext()/extractContext()) as the current context. */
    public any function runInContext(required any ctx, required any fn, struct args = {}) {
        var st = this.__state;
        if (!st.enabled || !isObject(arguments.ctx)) {
            var plain = arguments.fn(argumentCollection = arguments.args);
            if (!isNull(plain)) return plain;
            return;
        }
        var token = this._trackScope(st.bridge.makeContextCurrent(arguments.ctx));
        try {
            var result = arguments.fn(argumentCollection = arguments.args);
            if (!isNull(result)) return result;
        } finally {
            this._releaseScope(token);
        }
    }

    /**
     * Returns a closure that runs fn in the context captured NOW. Use it for anything that runs on
     * another thread, e.g. inside cfthread or with executors.
     */
    public any function bindContext(required any fn) {
        var ctx = this.captureContext();
        var target = arguments.fn;
        var self = this;
        return function() {
            return self.runInContext(ctx, target, arguments);
        };
    }

    /** Merge the propagation headers (traceparent, tracestate, baggage) for the current context into headers. */
    public struct function injectHeaders(struct headers = {}) {
        var st = this.__state;
        if (!st.enabled) return arguments.headers;
        var injected = st.bridge.injectHeaders(st.otel, this.captureContext());
        var keys = injected.keySet().toArray();
        for (var k in keys) {
            arguments.headers[k] = injected.get(k);
        }
        return arguments.headers;
    }

    /** W3C traceparent for the current context ("" if none). */
    public string function traceparent() {
        var h = this.injectHeaders({});
        return structKeyExists(h, "traceparent") ? h.traceparent : "";
    }

    /** Context carrying a remote parent from inbound headers (defaults to this request's headers). */
    public any function extractContext(struct headers) {
        var st = this.__state;
        if (!st.enabled) return "";
        if (isNull(arguments.headers)) arguments.headers = getHttpRequestData().headers;
        return st.bridge.extractContext(st.otel, arguments.headers);
    }

    // ------------------------------------------------------------------------------------------
    // Outbound HTTP
    // ------------------------------------------------------------------------------------------

    /**
     * Trace an outbound HTTP call that fn makes. fn(headers, span) must send `headers` (traceparent etc.)
     * with the request and should return the cfhttp result, whose status code is then recorded
     * (4xx/5xx and connection failures mark the span as an error). Returns fn's result.
     *
     * Creates a CLIENT span per the HTTP semantic conventions, unless the agent already traces cfhttp
     * correctly (ACF with the agent's HttpClient instrumentation on; see status().httpMode): then fn
     * just runs, and `span` is a no-op, so the same code works on every engine without double spans.
     *
     * options: method (default GET), urlTemplate (low-cardinality route, e.g. "/orders/{id}": names the
     *          span "GET /orders/{id}"), name (overrides the span name), attributes (struct)
     */
    public any function httpSpan(required string url, required any fn, struct options = {}) {
        var st = this.__state;
        var o = arguments.options;
        var target = arguments.fn;
        var self = this;
        var setup = {};
        if (st.enabled && st.httpMode == "span") {
            // Working out the span's name and attributes must never stop the call itself: if that fails
            // (an unparseable URL, say), fn still runs, untraced
            try {
                var method = structKeyExists(o, "method") && len(o.method) ? o.method : "GET";
                var template = structKeyExists(o, "urlTemplate") ? o.urlTemplate : "";
                var attrs = this._toCfml(st.bridge.httpClientAttributes(method, arguments.url));
                if (len(template)) attrs["url.template"] = template;
                if (structKeyExists(o, "attributes")) structAppend(attrs, o.attributes, true);
                setup = { "attributes": attrs,
                    "name": structKeyExists(o, "name") && len(o.name) ? o.name : st.bridge.httpSpanName(method, template) };
            } catch (any setupError) {
                setup = {};
            }
        }
        if (structIsEmpty(setup)) {
            var plain = target(this.injectHeaders({}), st.noopSpan);
            if (!isNull(plain)) return plain;
            return;
        }
        // span() makes the CLIENT span current, records an exception from fn and always ends the span
        return this.span(setup.name, function(s) {
            try {
                var result = target(self.injectHeaders({}), s);
            } catch (any e) {
                s.setAttribute("error.type", len(e.type) ? e.type : "_OTHER");
                rethrow;
            }
            if (!isNull(result)) {
                try {
                    self._recordHttpResult(s, result);
                } catch (any ignored) {
                    // an odd result must not turn a finished call into a failure
                }
                return result;
            }
        }, { "kind": "client", "attributes": setup.attributes });
    }

    /**
     * cfhttp with tracing: httpSpan() around a cfhttp call built from options. Returns the cfhttp result.
     *
     * options: method, headers (struct), body (string), params (array of cfhttpparam attribute structs),
     *          timeout (seconds), cfhttp (struct of any other cfhttp attributes: charset, redirect,
     *          username, password, throwOnError, getAsBinary, clientCert, proxyServer, ...),
     *          plus httpSpan()'s urlTemplate, name, attributes
     */
    public any function http(required string url, struct options = {}) {
        var o = arguments.options;
        var a = structKeyExists(o, "cfhttp") ? duplicate(o.cfhttp) : {};
        a["url"] = arguments.url;
        a["method"] = structKeyExists(o, "method") && len(o.method) ? uCase(o.method) : "GET";
        if (structKeyExists(o, "timeout")) a["timeout"] = o.timeout;
        var params = structKeyExists(o, "params") ? duplicate(o.params) : [];
        if (structKeyExists(o, "body")) arrayAppend(params, { "type": "body", "value": o.body });
        var userHeaders = structKeyExists(o, "headers") ? o.headers : {};
        var self = this;
        return this.httpSpan(arguments.url, function(traceHeaders, s) {
            return self._cfhttp(a, params, userHeaders, traceHeaders);
        }, o);
    }

    /** @hint internal: the cfhttp call behind http(). Trace headers win over caller headers of the same name. */
    public any function _cfhttp(required struct attrs, required array params, required struct headers, required struct traceHeaders) {
        var h = duplicate(arguments.headers);
        for (var k in arguments.traceHeaders) {
            for (var existing in structKeyArray(h)) {
                if (existing != k && compareNoCase(existing, k) == 0) structDelete(h, existing);
            }
            h[k] = arguments.traceHeaders[k];
        }
        cfhttp(attributeCollection = arguments.attrs, result = "local.res") {
            for (var hk in h) cfhttpparam(type = "header", name = hk, value = h[hk]);
            for (var p in arguments.params) cfhttpparam(attributeCollection = p);
        }
        return local.res;
    }

    /** @hint internal: status code / error onto a CLIENT span from a cfhttp result */
    public void function _recordHttpResult(required any span, required any result) {
        if (!isStruct(arguments.result)) return;
        var r = arguments.result;
        var raw = structKeyExists(r, "statusCode") ? r.statusCode : (structKeyExists(r, "status_code") ? r.status_code : "");
        var code = this.__state.bridge.httpStatusCode(raw);
        if (code > 0) {
            arguments.span.setAttribute("http.response.status_code", code);
            if (code >= 400) {
                arguments.span.setAttribute("error.type", toString(code));
                arguments.span.setStatus("ERROR");
            }
        } else if (structKeyExists(r, "errorDetail") && len(trim(r.errorDetail))) {
            arguments.span.setAttribute("error.type", "_OTHER");
            arguments.span.setStatus("ERROR", r.errorDetail);
        }
    }

    // ------------------------------------------------------------------------------------------
    // Scope tracking. A Scope left open on a pooled request thread leaks the span into later,
    // unrelated requests, so every scope this library opens is registered per thread and
    // onRequestEnd() closes whatever is left ON THE CALLING THREAD. Scopes can only be closed by the
    // thread that opened them, so on cfthread/runAsync threads use span()/runInContext()/
    // bindContext() (which clean up after themselves) or call onRequestEnd() at the end of the thread.
    //
    // OTel ignores Scope.close() unless that scope is the innermost one on the thread, so scopes
    // are always closed innermost-first: closing a token also closes anything opened after it.
    // ------------------------------------------------------------------------------------------

    /**
     * Close a scope token returned by span.makeCurrent(). Must be called on the thread that opened it.
     * Scopes opened after it on this thread and still open (leaked) are closed first.
     */
    public void function closeScope(required string token) {
        var st = this.__state;
        if (!st.enabled || !len(arguments.token)) return;
        var reg = this._threadRegistry();
        if (!structKeyExists(reg, arguments.token)) {
            throw(type = "cfmlotel.ScopeNotOpenOnThisThread",
                message = "Scope token is not open on this thread",
                detail = "Scopes must be closed on the thread that opened them (cfthread/runAsync run on other threads).");
        }
        var leaked = this._closeScopes(reg, reg[arguments.token].seq) - 1;
        if (leaked > 0 && st.config.logLeakedScopes) {
            writeLog(type = "warning", file = "cfml-otel",
                text = "cfml-otel closed #leaked# leaked OpenTelemetry scope(s) left open inside an enclosing scope (trace #this.traceId()#)");
        }
    }

    /**
     * @hint internal: closeScope() for scopes the library opened itself (span(), runInContext()). A token
     * that is no longer open (already cleaned up) is fine here; closeScope() treats it as a caller error.
     */
    public void function _releaseScope(required string token) {
        if (!this.__state.enabled || !len(arguments.token)) return;
        if (structKeyExists(this._threadRegistry(), arguments.token)) this.closeScope(arguments.token);
    }

    /** @hint internal: closes this thread's scopes opened at or after minSeq, innermost first; returns how many */
    public numeric function _closeScopes(required any reg, numeric minSeq = 0) {
        var st = this.__state;
        var tokens = structSort(arguments.reg, "numeric", "desc", "seq");
        var closed = 0;
        for (var t in tokens) {
            var entry = arguments.reg[t];
            if (entry.seq < arguments.minSeq) break;
            structDelete(arguments.reg, t);
            try {
                st.bridge.closeScope(entry.scope);
            } catch (any ignored) {}
            closed++;
        }
        return closed;
    }

    /**
     * Call from Application.cfc onRequestEnd(). Closes leaked scopes on this thread (returns how many) and,
     * in sdkFallback mode, ends the request's SERVER span (only on the thread that started it).
     */
    public numeric function onRequestEnd() {
        var st = this.__state;
        if (!st.enabled) return 0;
        var closed = this.closeLeakedScopes("at request end");
        var srv = this._serverOnThisThread();
        if (!structIsEmpty(srv)) {
            var reg = this._threadRegistry();
            if (structKeyExists(reg, srv.token)) this._closeScopes(reg, reg[srv.token].seq);
            this._endServerSpan();
        }
        return closed;
    }

    /**
     * Call from Application.cfc onAbort(). cfabort and cflocation end a request through onAbort(), and
     * neither engine runs onRequestEnd() then: without this call the request's scopes stay open on the pooled
     * thread and, in sdkFallback mode, its SERVER span is never ended. Same work as onRequestEnd(), and safe
     * to call when that runs as well.
     */
    public numeric function onAbort() {
        this.__state.abortHookSeen = true;
        return this.onRequestEnd();
    }

    /**
     * For code that has to clean up BEFORE a redirect it can't see finish: ColdBox's relocate() announces
     * postProcess and only then sends cflocation, which aborts the request. Closes the leaked scopes like
     * onRequestEnd(). In sdkFallback mode the response doesn't carry the redirect's status yet, so:
     * if the app's onAbort() calls otel.onAbort() (seen at least once), the SERVER span is left for that call,
     * which records the real status; otherwise it is ended here without a status code rather than a wrong one.
     */
    public numeric function onRedirecting() {
        var st = this.__state;
        if (!st.enabled) return 0;
        var srv = this._serverOnThisThread();
        if (structIsEmpty(srv)) return this.onRequestEnd();
        if (st.abortHookSeen) return this.closeLeakedScopes("at request end");
        srv.statusUnknown = true;
        return this.onRequestEnd();
    }

    /** True while this thread's request has an sdkFallback SERVER span that hasn't been ended. */
    public boolean function hasServerSpan() {
        return this.__state.enabled && !structIsEmpty(this._serverOnThisThread());
    }

    /**
     * Close the scopes left open on this thread, innermost first; returns how many. Call it at the end of a
     * cfthread/runAsync body that used makeCurrent() directly. Never closes the sdkFallback SERVER scope.
     */
    public numeric function closeLeakedScopes(string when = "") {
        var st = this.__state;
        if (!st.enabled) return 0;
        var reg = this._threadRegistry();
        var srv = this._serverOnThisThread();
        var minSeq = (!structIsEmpty(srv) && structKeyExists(reg, srv.token)) ? reg[srv.token].seq + 1 : 0;
        var closed = this._closeScopes(reg, minSeq);
        if (closed && st.config.logLeakedScopes) {
            writeLog(type = "warning", file = "cfml-otel",
                text = "cfml-otel closed #closed# leaked OpenTelemetry scope(s)#len(arguments.when) ? ' ' & arguments.when : ''# (trace #this.traceId()#)");
        }
        return closed;
    }

    /** @hint internal: the sdkFallback SERVER span record if this thread started it, else {} */
    public struct function _serverOnThisThread() {
        if (!structKeyExists(request, "__cfmlotelServer")) return {};
        var srv = request.__cfmlotelServer;
        return srv.thread == this.__state.jThread.currentThread().getId() ? srv : {};
    }

    /**
     * Call from Application.cfc onError(). Marks the current span as failed and cleans up scopes.
     * Neither engine runs onRequestEnd() after onError(), so in sdkFallback mode this also ends the SERVER
     * span: set the response status (cfheader statuscode=...) BEFORE calling it, or pass statusCode.
     */
    public void function onError(required any exception, numeric statusCode = 0) {
        if (!this.__state.enabled) return;
        var err = arguments.exception;
        // onError wraps the real error in a struct with a rootCause key on both engines
        if (isStruct(err) && structKeyExists(err, "rootCause")) err = err.rootCause;
        var srv = this._serverOnThisThread();
        if (!structIsEmpty(srv)) {
            // the request thread's fallback SERVER span: record here, then end it (nothing else will)
            try {
                srv.span.recordException(err);
                var et = isStruct(err) && structKeyExists(err, "type") && len(err.type) ? err.type : "_OTHER";
                srv.span.setAttribute("error.type", et);
                srv.span.setStatus("ERROR", isStruct(err) && structKeyExists(err, "message") ? err.message : "");
                srv.errorType = et;
                if (arguments.statusCode > 0) srv.statusCode = arguments.statusCode;
            } catch (any ignored) {}
            this.onRequestEnd();
            return;
        }
        this.onRequestEnd();
        try {
            var s = this.currentSpan();
            s.recordException(err);
            s.setStatus("ERROR", isStruct(err) && structKeyExists(err, "message") ? err.message : "");
        } catch (any ignored) {}
    }

    /** @hint internal: used by Span.makeCurrent() */
    public string function _trackScope(required any javaScope) {
        var reg = this._threadRegistry();
        var token = createUUID();
        // seq orders scopes so they can be closed innermost-first. A process-wide counter in the bridge,
        // not a clock: two scopes opened back to back always get distinct, increasing values.
        reg[token] = { "scope": arguments.javaScope, "seq": this.__state.bridge.nextScopeSeq() };
        return token;
    }

    /** @hint internal */
    public struct function _threadRegistry() {
        if (!structKeyExists(request, "__cfmlotel")) {
            lock scope="request" type="exclusive" timeout="5" {
                if (!structKeyExists(request, "__cfmlotel")) {
                    request.__cfmlotel = createObject("java", "java.util.concurrent.ConcurrentHashMap").init();
                }
            }
        }
        var tid = "t" & this.__state.jThread.currentThread().getId();
        var reg = request.__cfmlotel.get(tid);
        if (isNull(reg)) {
            request.__cfmlotel.putIfAbsent(tid, {});
            reg = request.__cfmlotel.get(tid);
        }
        return reg;
    }

    // ------------------------------------------------------------------------------------------
    // Metrics. Instruments are cached by name; create them once and reuse.
    // ------------------------------------------------------------------------------------------

    public any function counter(required string name, string description = "", string unit = "", string valueType = "long") {
        return this._instrument("counter", arguments.valueType, arguments.name, arguments.description, arguments.unit);
    }

    public any function upDownCounter(required string name, string description = "", string unit = "", string valueType = "long") {
        return this._instrument("upDownCounter", arguments.valueType, arguments.name, arguments.description, arguments.unit);
    }

    public any function histogram(required string name, string description = "", string unit = "", string valueType = "double") {
        return this._instrument("histogram", arguments.valueType, arguments.name, arguments.description, arguments.unit);
    }

    public any function gauge(required string name, string description = "", string unit = "", string valueType = "double") {
        return this._instrument("gauge", arguments.valueType, arguments.name, arguments.description, arguments.unit);
    }

    /** @hint internal */
    public any function _instrument(type, valueType, name, description, unit) {
        var st = this.__state;
        if (!st.enabled) return createObject("component", st.pkg & "Instrument").init("", "", false);
        var key = lCase(arguments.type & "|" & arguments.valueType & "|" & arguments.name);
        if (!structKeyExists(st.instruments, key)) {
            lock name="cfmlotel.instruments" type="exclusive" timeout="5" {
                if (!structKeyExists(st.instruments, key)) {
                    var ji = st.bridge.instrument(st.meter, arguments.type, arguments.valueType,
                        arguments.name, arguments.description, arguments.unit);
                    st.instruments[key] = createObject("component", st.pkg & "Instrument").init(st.bridge, ji, true, lCase(arguments.valueType), arguments.name);
                }
            }
        }
        return st.instruments[key];
    }

    // ------------------------------------------------------------------------------------------
    // Logs (OTel Logs API; records carry the current trace/span IDs)
    // ------------------------------------------------------------------------------------------

    /** severity: trace|debug|info|warn|error|fatal */
    public any function emitLog(required string severity, required string message, struct attributes = {}) {
        var st = this.__state;
        if (st.enabled) {
            st.bridge.emitLog(st.logger, arguments.severity, arguments.message, arguments.attributes);
        }
        return this;
    }

    public any function logDebug(required string message, struct attributes = {}) {
        return this.emitLog("debug", arguments.message, arguments.attributes);
    }

    public any function logInfo(required string message, struct attributes = {}) {
        return this.emitLog("info", arguments.message, arguments.attributes);
    }

    public any function logWarn(required string message, struct attributes = {}) {
        return this.emitLog("warn", arguments.message, arguments.attributes);
    }

    public any function logError(required string message, struct attributes = {}) {
        return this.emitLog("error", arguments.message, arguments.attributes);
    }
}
