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
            "bridgeVersion": ""
        };
        var st = this.__state;
        // Class handle used on every scope open/close; looked up once instead of per span
        st.jThread = createObject("java", "java.lang.Thread");
        // Resolve sibling components by full dotted path: relative `new Span()` can resolve against the
        // wrong template under the ACF thread bug described above.
        var myName = getMetadata(this).name;
        st.pkg = listLen(myName, ".") > 1 ? listDeleteAt(myName, listLen(myName, "."), ".") & "." : "";

        if (!cfg.enabled) {
            st.reason = "disabled by configuration";
            return this;
        }
        try {
            st.bridge = createObject("java", cfg.bridgeClass);
            var meterName = len(cfg.meterName) ? cfg.meterName : cfg.tracerName;
            var loggerName = len(cfg.loggerName) ? cfg.loggerName : cfg.tracerName;
            st.tracer = st.bridge.tracer(cfg.tracerName, cfg.tracerVersion);
            st.meter = st.bridge.meter(meterName, cfg.tracerVersion);
            st.logger = st.bridge.logger(loggerName);
            st.bridgeVersion = st.bridge.version();
            st.agentBridged = st.bridge.isAgentBridged();
            st.active = st.bridge.isActive();
            st.enabled = true;
            if (!st.active) st.reason = "OpenTelemetry API loaded but no SDK/agent is active (no-op)";
        } catch (any e) {
            st.reason = "could not load #cfg.bridgeClass# (are cfml-otel/lib jars in this.javaSettings.loadPaths?): " & e.message;
        }
        return this;
    }

    // ------------------------------------------------------------------------------------------
    // Status
    // ------------------------------------------------------------------------------------------

    public boolean function isEnabled() {
        return this.__state.enabled;
    }

    public struct function status() {
        var st = this.__state;
        return {
            "enabled": st.enabled,
            "active": st.active,
            "agentBridged": st.agentBridged,
            "bridgeVersion": st.bridgeVersion,
            "implementation": st.enabled ? st.bridge.implementationClass() : "",
            "reason": st.reason
        };
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
        if (!st.enabled) return createObject("component", st.pkg & "Span").init(this, "", "", false, false);
        var kind = structKeyExists(arguments.options, "kind") ? arguments.options.kind : "internal";
        var attributes = structKeyExists(arguments.options, "attributes") ? arguments.options.attributes : {};
        var parent = structKeyExists(arguments.options, "parent") ? arguments.options.parent : "";
        var js = st.bridge.startSpan(st.tracer, arguments.name, kind, attributes, parent);
        return createObject("component", st.pkg & "Span").init(this, st.bridge, js, true, true);
    }

    /** The current span (usually the agent's SERVER span or an enclosing span()). end() on it is ignored. */
    public any function currentSpan() {
        var st = this.__state;
        if (!st.enabled) return createObject("component", st.pkg & "Span").init(this, "", "", false, false);
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
        var injected = st.bridge.injectHeaders(this.captureContext());
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
        return st.bridge.extractContext(arguments.headers);
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
     * Call from Application.cfc onRequestEnd(). Closes leaked scopes on this thread; returns how many.
     * Also safe to call at the end of a cfthread/runAsync body that used makeCurrent() directly.
     */
    public numeric function onRequestEnd() {
        var st = this.__state;
        if (!st.enabled) return 0;
        var closed = this._closeScopes(this._threadRegistry());
        if (closed && st.config.logLeakedScopes) {
            writeLog(type = "warning", file = "cfml-otel",
                text = "cfml-otel closed #closed# leaked OpenTelemetry scope(s) at request end (trace #this.traceId()#)");
        }
        return closed;
    }

    /** Call from Application.cfc onError(). Marks the current span as failed and cleans up scopes. */
    public void function onError(required any exception) {
        if (!this.__state.enabled) return;
        var err = arguments.exception;
        // onError wraps the real error in a struct with a rootCause key on both engines
        if (isStruct(err) && structKeyExists(err, "rootCause")) err = err.rootCause;
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
