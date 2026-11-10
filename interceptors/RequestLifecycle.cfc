/**
 * ColdBox request lifecycle hooks: starts the SERVER span in sdkFallback mode (the agent makes it otherwise),
 * tags the SERVER span with the ColdBox event and route
 * (coldbox.event / coldbox.route attributes; the span keeps the agent's name), records unhandled
 * exceptions on it, and closes any scopes left open at the end of the request.
 *
 * Interception data arrives as `data` (ColdBox 7+); `interceptData` is the deprecated older name and is
 * read as a fallback.
 */
component {

    property name="otel" inject="OTel@cfmlotel";
    // mapped by ModuleConfig.cfc to this module's settings, whatever folder the module is installed in
    property name="settings" inject="settings@cfmlotel";

    function preProcess(event, data, rc, prc) {
        // sdkFallback (no agent): starts the request's SERVER span; a no-op with the agent
        otel.onRequestStart();
        if (!settings.traceEvents) return;
        otel.currentSpan()
            .setAttributes({ "coldbox.event": event.getCurrentEvent(), "coldbox.route": event.getCurrentRoutedURL() });
    }

    function onException(event, data, rc, prc) {
        // postProcess does not run when the event throws, so onError() closes leaked scopes here
        // and then records the exception on the SERVER span rather than on a leaked inner span.
        var payload = interceptionData(arguments);
        if (structKeyExists(payload, "exception")) {
            // 500: ColdBox sets that status right after announcing onException, so the response doesn't carry
            // it yet when the sdkFallback SERVER span is ended here
            otel.onError(payload.exception, 500);
        } else {
            otel.onRequestEnd();
        }
    }

    function postProcess(event, data, rc, prc) {
        // relocate() announces postProcess and then redirects. Only the sdkFallback SERVER span cares (the
        // redirect's status isn't on the response yet), so the call stack is only read when there is one.
        if (otel.hasServerSpan() && insideRelocate()) {
            otel.onRedirecting();
        } else {
            otel.onRequestEnd();
        }
    }

    /** True when this interception was announced from ColdBox's Controller.relocate(). */
    private boolean function insideRelocate() {
        try {
            for (var frame in callStackGet()) {
                if (frame.function == "relocate"
                    && findNoCase("Controller.", listLast(replace(frame.template, "\", "/", "all"), "/")) == 1) return true;
            }
        } catch (any ignored) {
        }
        return false;
    }

    private struct function interceptionData(required struct args) {
        if (structKeyExists(arguments.args, "data") && isStruct(arguments.args.data)) return arguments.args.data;
        if (structKeyExists(arguments.args, "interceptData") && isStruct(arguments.args.interceptData)) return arguments.args.interceptData;
        return {};
    }
}
