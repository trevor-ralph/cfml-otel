package cfmlotel.bridge;

import io.opentelemetry.sdk.OpenTelemetrySdk;
import io.opentelemetry.sdk.autoconfigure.AutoConfiguredOpenTelemetrySdk;

import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.TimeUnit;

/**
 * cfml-otel's own OpenTelemetry SDK, for JVMs without the javaagent (opt-in: sdkFallback). Only this class
 * touches SDK types, and OtelBridge only loads it when the fallback is requested, so the SDK jars in
 * lib/sdk/ are needed only then.
 *
 * <p>One SDK per class loader: applications that share cfml-otel's jars through one class loader share it
 * (the first one's service.name wins), and it is shut down when the last of them releases it.
 */
final class SdkFallback {

  private static OpenTelemetrySdk sdk;
  private static String serviceName = "";
  private static int users;

  private SdkFallback() {}

  static synchronized Map<String, Object> start(Map<?, ?> defaults) {
    Map<String, Object> r = new HashMap<>();
    r.put("shared", false);
    r.put("error", "");
    if (sdk != null) {
      users++;
      r.put("started", true);
      r.put("shared", true);
      r.put("serviceName", serviceName);
      return r;
    }
    Map<String, String> props = new HashMap<>();
    // The javaagent's defaults, so switching between agent and fallback needs no config change
    props.put("otel.exporter.otlp.protocol", "http/protobuf");
    if (defaults != null) {
      for (Map.Entry<?, ?> e : defaults.entrySet()) {
        if (e.getKey() != null && e.getValue() != null && !String.valueOf(e.getValue()).isEmpty()) {
          props.put(String.valueOf(e.getKey()), String.valueOf(e.getValue()));
        }
      }
    }
    try {
      // Defaults only: OTEL_* environment variables and otel.* system properties still take precedence
      AutoConfiguredOpenTelemetrySdk auto = AutoConfiguredOpenTelemetrySdk.builder()
          .addPropertiesSupplier(() -> props)
          .build();
      sdk = auto.getOpenTelemetrySdk();
    } catch (RuntimeException e) {
      r.put("started", false);
      r.put("serviceName", "");
      r.put("error", "the OpenTelemetry SDK could not be configured: " + e);
      return r;
    }
    users = 1;
    String configured = Diagnostics.config("otel.service.name");
    serviceName = !configured.isEmpty() ? configured : props.getOrDefault("otel.service.name", "");
    OtelBridge.setFallback(sdk);
    r.put("started", true);
    r.put("serviceName", serviceName);
    return r;
  }

  static synchronized void flush() {
    if (sdk == null) return;
    sdk.getSdkTracerProvider().forceFlush().join(10, TimeUnit.SECONDS);
    sdk.getSdkMeterProvider().forceFlush().join(10, TimeUnit.SECONDS);
    sdk.getSdkLoggerProvider().forceFlush().join(10, TimeUnit.SECONDS);
  }

  static synchronized void release() {
    if (sdk == null) return;
    if (--users > 0) {
      flush();
      return;
    }
    OpenTelemetrySdk s = sdk;
    OtelBridge.setFallback(null);
    sdk = null;
    serviceName = "";
    users = 0;
    s.shutdown().join(10, TimeUnit.SECONDS);
  }
}
