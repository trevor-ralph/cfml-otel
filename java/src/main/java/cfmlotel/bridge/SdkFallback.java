package cfmlotel.bridge;

import io.opentelemetry.sdk.OpenTelemetrySdk;
import io.opentelemetry.sdk.autoconfigure.AutoConfiguredOpenTelemetrySdk;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.TimeUnit;

/**
 * cfml-otel's own OpenTelemetry SDKs, for JVMs without the javaagent (opt-in: sdkFallback). Only this class
 * touches SDK types, and OtelBridge only loads it when the fallback is used, so the SDK jars in lib/sdk/ are
 * needed only then.
 *
 * <p>One SDK per OTel CFC instance, never shared: applications that load these classes through one class
 * loader (Lucee 6 does that even for separate copies of the same jars) still each get their own
 * service.name. Instances that are never shut down are flushed by one JVM shutdown hook.
 */
final class SdkFallback {

  private static final Set<OpenTelemetrySdk> LIVE = new LinkedHashSet<>();
  private static boolean hookRegistered;

  private SdkFallback() {}

  static Map<String, Object> start(Map<?, ?> defaults, Map<?, ?> overrides) {
    Map<String, Object> r = new HashMap<>();
    r.put("error", "");
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
    Map<String, String> forced = new HashMap<>();
    if (overrides != null) {
      for (Map.Entry<?, ?> e : overrides.entrySet()) {
        if (e.getKey() != null && e.getValue() != null && !String.valueOf(e.getValue()).isEmpty()) {
          forced.put(String.valueOf(e.getKey()), String.valueOf(e.getValue()));
        }
      }
    }
    OpenTelemetrySdk sdk;
    try {
      // defaults: below OTEL_* env vars and otel.* system properties; overrides (explicit CFC options): above them.
      // Not registered as GlobalOpenTelemetry (one per class loader); the CFC holds the handle instead.
      sdk = AutoConfiguredOpenTelemetrySdk.builder()
          .addPropertiesSupplier(() -> props)
          .addPropertiesCustomizer(config -> forced)
          .disableShutdownHook()
          .build()
          .getOpenTelemetrySdk();
    } catch (RuntimeException e) {
      r.put("started", false);
      r.put("serviceName", "");
      r.put("error", "the OpenTelemetry SDK could not be configured: " + e);
      return r;
    }
    register(sdk);
    String configured = Diagnostics.config("otel.service.name");
    String name = forced.containsKey("otel.service.name") ? forced.get("otel.service.name")
        : !configured.isEmpty() ? configured : props.getOrDefault("otel.service.name", "");
    r.put("started", true);
    r.put("serviceName", name);
    r.put("sdk", sdk);
    return r;
  }

  private static synchronized void register(OpenTelemetrySdk sdk) {
    LIVE.add(sdk);
    if (!hookRegistered) {
      hookRegistered = true;
      Runtime.getRuntime().addShutdownHook(new Thread(SdkFallback::shutdownAll, "cfml-otel-sdk-shutdown"));
    }
  }

  static void shutdown(Object handle) {
    OpenTelemetrySdk sdk;
    synchronized (SdkFallback.class) {
      if (!(handle instanceof OpenTelemetrySdk) || !LIVE.remove(handle)) return;
      sdk = (OpenTelemetrySdk) handle;
    }
    sdk.shutdown().join(10, TimeUnit.SECONDS);
  }

  static synchronized int liveCount() {
    return LIVE.size();
  }

  private static void shutdownAll() {
    List<OpenTelemetrySdk> all;
    synchronized (SdkFallback.class) {
      all = new ArrayList<>(LIVE);
      LIVE.clear();
    }
    for (OpenTelemetrySdk sdk : all) sdk.shutdown().join(10, TimeUnit.SECONDS);
  }
}
