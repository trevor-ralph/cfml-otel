/**
 * A metric instrument handle (counter, up-down counter, histogram or gauge). Get one from
 * otel.counter() / upDownCounter() / histogram() / gauge(); they are cached, so call freely.
 * State lives in this.__state, not variables (see the note in OTel.cfc about ACF 2025).
 */
component {

    public function init(required any bridge, required any javaInstrument, boolean live = true, string valueType = "double", string name = "") {
        this.__state = {
            "bridge": arguments.bridge,
            "ji": arguments.javaInstrument,
            "live": arguments.live,
            "isLong": arguments.valueType == "long",
            "name": arguments.name,
            "warned": false
        };
        return this;
    }

    /** Counter / up-down counter: add a (possibly negative, for up-down) amount. */
    public any function add(numeric value = 1, struct attributes = {}) {
        var st = this.__state;
        if (st.live) st.bridge.record(st.ji, this._value(arguments.value), arguments.attributes);
        return this;
    }

    /** Histogram: record a measurement. */
    public any function record(required numeric value, struct attributes = {}) {
        var st = this.__state;
        if (st.live) st.bridge.record(st.ji, this._value(arguments.value), arguments.attributes);
        return this;
    }

    /** Gauge: set the current value. */
    public any function set(required numeric value, struct attributes = {}) {
        var st = this.__state;
        if (st.live) st.bridge.record(st.ji, this._value(arguments.value), arguments.attributes);
        return this;
    }

    /**
     * @hint internal: a long instrument can't hold fractions. Round to nearest and warn once per
     * instrument, so the loss is visible instead of silently truncating (0.7 -> 0).
     */
    public numeric function _value(required numeric value) {
        var st = this.__state;
        if (!st.isLong || arguments.value == fix(arguments.value)) return arguments.value;
        if (!st.warned) {
            st.warned = true;
            writeLog(type = "warning", file = "cfml-otel",
                text = "cfml-otel instrument '#st.name#' is long-valued but got the fractional value #arguments.value#; values are rounded. Create it with valueType=""double"" to keep fractions.");
        }
        return round(arguments.value);
    }
}
