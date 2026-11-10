package cfmlotel.bridge;

import io.opentelemetry.sdk.common.export.HttpSender;
import io.opentelemetry.sdk.common.export.HttpSenderConfig;
import io.opentelemetry.sdk.common.export.HttpSenderProvider;

/** ServiceLoader entry (META-INF/services) that gives the SDK fallback's OTLP/HTTP exporters their sender. */
public final class UrlConnectionHttpSenderProvider implements HttpSenderProvider {

  @Override
  public HttpSender createSender(HttpSenderConfig config) {
    return new UrlConnectionHttpSender(config);
  }
}
