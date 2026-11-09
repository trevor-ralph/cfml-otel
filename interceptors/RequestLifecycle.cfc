/**
 * ColdBox request lifecycle hooks: tags the agent's SERVER span with the ColdBox event and route
 * (coldbox.event / coldbox.route attributes; the span keeps the agent's name), records unhandled
 * exceptions on it, and closes any scopes left open at the end of the request.
 *
 * Interception data arrives as `data` (ColdBox 7+); `interceptData` is the deprecated older name and is
 * read as a fallback.
 */
component {

    property name="otel" inject="OTel@cfmlotel";
    property name="settings" inject="coldbox:moduleSettings:cfml-otel";

    function preProcess(event, data, rc, prc) {
        if (!settings.traceEvents) return;
        otel.currentSpan()
            .setAttributes({ "coldbox.event": event.getCurrentEvent(), "coldbox.route": event.getCurrentRoutedURL() });
    }

    function onException(event, data, rc, prc) {
        // postProcess does not run when the event throws, so onError() closes leaked scopes here
        // and then records the exception on the SERVER span rather than on a leaked inner span.
        var payload = interceptionData(arguments);
        if (structKeyExists(payload, "exception")) {
            otel.onError(payload.exception);
        } else {
            otel.onRequestEnd();
        }
    }

    function postProcess(event, data, rc, prc) {
        otel.onRequestEnd();
    }

    private struct function interceptionData(required struct args) {
        if (structKeyExists(arguments.args, "data") && isStruct(arguments.args.data)) return arguments.args.data;
        if (structKeyExists(arguments.args, "interceptData") && isStruct(arguments.args.interceptData)) return arguments.args.interceptData;
        return {};
    }
}
