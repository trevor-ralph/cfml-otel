/**
 * A span handle. Methods are chainable. Created by OTel.span()/startSpan()/currentSpan().
 * Never call methods on getJavaSpan() directly from CFML (see README: agent bridge classes).
 * State lives in this.__state, not variables (see the note in OTel.cfc about ACF 2025).
 */
component {

    public function init(required any otel, required any bridge, required any javaSpan, boolean owned = true, boolean live = true) {
        this.__state = {
            "otel": arguments.otel,
            "bridge": arguments.bridge,
            "js": arguments.javaSpan,
            "owned": arguments.owned,   // false for currentSpan(): we must not end someone else's span
            "live": arguments.live,     // false when cfml-otel is disabled (no-op span)
            "ended": false
        };
        return this;
    }

    public any function setAttribute(required string key, required any value) {
        var st = this.__state;
        if (st.live) st.bridge.setAttribute(st.js, arguments.key, arguments.value);
        return this;
    }

    public any function setAttributes(required struct attributes) {
        var st = this.__state;
        if (st.live) st.bridge.setAttributes(st.js, arguments.attributes);
        return this;
    }

    public any function addEvent(required string name, struct attributes = {}) {
        var st = this.__state;
        if (st.live) st.bridge.addEvent(st.js, arguments.name, arguments.attributes);
        return this;
    }

    /** Accepts a catch variable, a Java Throwable, or an onError exception. */
    public any function recordException(required any error, struct attributes = {}) {
        var st = this.__state;
        if (st.live) st.bridge.recordException(st.js, arguments.error, arguments.attributes);
        return this;
    }

    /** code: OK | ERROR | UNSET */
    public any function setStatus(required string code, string description = "") {
        var st = this.__state;
        if (st.live) st.bridge.setStatus(st.js, arguments.code, arguments.description);
        return this;
    }

    public any function updateName(required string name) {
        var st = this.__state;
        if (st.live) st.bridge.updateName(st.js, arguments.name);
        return this;
    }

    /** Make this span current on this thread. Returns a token for otel.closeScope(token). */
    public string function makeCurrent() {
        var st = this.__state;
        if (!st.live) return "";
        return st.otel._trackScope(st.bridge.makeSpanCurrent(st.js));
    }

    /** A context with this span as parent, e.g. to parent work on another thread via otel.runInContext(). */
    public any function context() {
        var st = this.__state;
        if (!st.live) return "";
        return st.bridge.contextWithSpan(st.bridge.currentContext(), st.js);
    }

    public void function end() {
        var st = this.__state;
        if (st.live && st.owned && !st.ended) {
            st.ended = true;
            st.bridge.endSpan(st.js);
        }
    }

    public string function getTraceId() {
        var st = this.__state;
        return st.live ? st.bridge.spanTraceId(st.js) : "";
    }

    public string function getSpanId() {
        var st = this.__state;
        return st.live ? st.bridge.spanSpanId(st.js) : "";
    }

    public boolean function isRecording() {
        var st = this.__state;
        return st.live && st.bridge.isRecording(st.js);
    }

    public any function getJavaSpan() {
        return this.__state.js;
    }
}
