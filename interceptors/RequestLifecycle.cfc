/**
 * ColdBox request lifecycle hooks: names the agent's SERVER span after the ColdBox event, records
 * unhandled exceptions on it, and closes any scopes left open at the end of the request.
 */
component {

    property name="otel" inject="OTel@cfmlotel";
    property name="settings" inject="coldbox:moduleSettings:cfml-otel";

    function preProcess(event, interceptData, rc, prc) {
        if (!settings.traceEvents) return;
        otel.currentSpan()
            .setAttributes({ "coldbox.event": event.getCurrentEvent(), "coldbox.route": event.getCurrentRoutedURL() });
    }

    function onException(event, interceptData, rc, prc) {
        if (structKeyExists(interceptData, "exception")) {
            otel.recordException(interceptData.exception);
        }
    }

    function postProcess(event, interceptData, rc, prc) {
        otel.onRequestEnd();
    }
}
