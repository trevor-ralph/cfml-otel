package cfmlotel.bridge;

import io.opentelemetry.context.Context;
import io.opentelemetry.instrumentation.api.internal.HttpRouteState;
import io.opentelemetry.instrumentation.api.semconv.http.HttpServerRoute;
import io.opentelemetry.instrumentation.api.semconv.http.HttpServerRouteSource;

/**
 * Sets the request's route through OpenTelemetry's instrumentation API. The javaagent bridges that API from
 * the application (its HttpRouteState instrumentation), so the route reaches the agent's own SERVER span: its
 * name ("GET route"), its http.route attribute and the http.route label on http.server.request.duration.
 *
 * <p>Kept apart from OtelBridge because opentelemetry-instrumentation-api is optional at runtime (lib/ ships
 * it, a bridge-only install may not have it): referencing it from here means a missing jar only fails the
 * call that needs it, with a NoClassDefFoundError that OtelBridge catches.
 */
final class ServerRoute {

  private ServerRoute() {}

  /** Where opentelemetry-instrumentation-api was loaded from (for setRoute()'s explanation when it fails). */
  static String location() {
    return Diagnostics.location(HttpRouteState.class);
  }

  /**
   * framework: a framework's own route (ColdBox), which the agent keeps first-come; otherwise the
   * application's, which takes precedence over a framework's and over the servlet mapping. Returns false when
   * the agent's route state isn't reachable from here: no agent SERVER span, or this jar isn't loaded by the
   * same class loader as opentelemetry-api (then the agent doesn't bridge it).
   */
  static boolean update(String route, boolean framework) {
    Context context = Context.current();
    // The agent's route state for this request, visible here only if the agent bridges this API. It doesn't when
    // this jar and opentelemetry-api come from different class loaders (e.g. the API on the server classpath and
    // this jar in loadPaths), and then the update below would silently do nothing.
    if (HttpRouteState.fromContextOrNull(context) == null) return false;
    HttpServerRoute.update(context,
        framework ? HttpServerRouteSource.CONTROLLER : HttpServerRouteSource.NESTED_CONTROLLER, route);
    return true;
  }
}
