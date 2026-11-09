/**
 * A metric instrument handle (counter, up-down counter, histogram or gauge). Get one from
 * otel.counter() / upDownCounter() / histogram() / gauge(); they are cached, so call freely.
 * State lives in this.__state, not variables (see the note in OTel.cfc about ACF 2025).
 */
component {

    public function init(required any bridge, required any javaInstrument, boolean live = true) {
        this.__state = { "bridge": arguments.bridge, "ji": arguments.javaInstrument, "live": arguments.live };
        return this;
    }

    /** Counter / up-down counter: add a (possibly negative, for up-down) amount. */
    public any function add(numeric value = 1, struct attributes = {}) {
        var st = this.__state;
        if (st.live) st.bridge.record(st.ji, arguments.value, arguments.attributes);
        return this;
    }

    /** Histogram: record a measurement. */
    public any function record(required numeric value, struct attributes = {}) {
        var st = this.__state;
        if (st.live) st.bridge.record(st.ji, arguments.value, arguments.attributes);
        return this;
    }

    /** Gauge: set the current value. */
    public any function set(required numeric value, struct attributes = {}) {
        var st = this.__state;
        if (st.live) st.bridge.record(st.ji, arguments.value, arguments.attributes);
        return this;
    }
}
