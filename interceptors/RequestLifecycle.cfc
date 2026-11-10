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
    property name="cbController" inject="coldbox";

    function preProcess(event, data, rc, prc) {
        // sdkFallback (no agent): starts the request's SERVER span; a no-op with the agent
        otel.onRequestStart();
        // a framework route: an application's own otel.setRoute() call still takes precedence
        // (not `settings.setRoute ?: true`: ACF's ?: treats false like null and would always give true)
        if (!structKeyExists(settings, "setRoute") || settings.setRoute) otel._setRoute(routeOf(event), true);
        if (!settings.traceEvents) return;
        otel.currentSpan()
            .setAttributes({ "coldbox.event": event.getCurrentEvent(), "coldbox.route": event.getCurrentRoutedURL() });
    }

    function onException(event, data, rc, prc) {
        // postProcess does not run when the event throws, so onError() closes leaked scopes here
        // and then records the exception on the SERVER span rather than on a leaked inner span.
        var payload = interceptionData(arguments);
        if (!structKeyExists(payload, "exception")) {
            otel.onRequestEnd();
            return;
        }
        // ColdBox sets 500 right after announcing onException, then runs the app's exceptionHandler event,
        // which may answer with another status (a 404 for a not-found error, say). With such a handler the
        // request is ended in postEvent, once that handler has set its status.
        var handler = exceptionHandlerEvent();
        if (len(handler)) {
            request.__cfmlotelExceptionHandler = handler;
            otel.onError(payload.exception, 0, false);
        } else {
            // no handler: the 500 is final, but not on the response yet when the sdkFallback SERVER span ends here
            otel.onError(payload.exception, 500);
        }
    }

    function postEvent(event, data, rc, prc) {
        // Only of interest after onException: the app's exceptionHandler event has finished, so the status is final
        if (!structKeyExists(request, "__cfmlotelExceptionHandler")) return;
        var payload = interceptionData(arguments);
        if (structKeyExists(payload, "processedEvent") && payload.processedEvent == request.__cfmlotelExceptionHandler) {
            structDelete(request, "__cfmlotelExceptionHandler");
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

    /**
     * The request's route for http.route: the matched route pattern ("/api/users/:id/"), or the event
     * ("main.index") when there is none or it is ColdBox's generic ":handler/:action?" convention route.
     */
    private string function routeOf(required any event) {
        try {
            var pattern = arguments.event.getCurrentRoute();
            if (len(pattern) && !findNoCase(":handler", pattern)) return "/" & reReplace(pattern, "^/+", "");
            return arguments.event.getCurrentEvent();
        } catch (any ignored) {
            return "";
        }
    }

    /** The app's exceptionHandler setting (an event name), or "" when it has none. */
    private string function exceptionHandlerEvent() {
        try {
            var h = cbController.getSetting("exceptionHandler", "");
            return isSimpleValue(h) ? trim(h) : "";
        } catch (any ignored) {
            return "";
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
