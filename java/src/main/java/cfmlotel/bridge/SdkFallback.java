package cfmlotel.bridge;

import io.opentelemetry.sdk.OpenTelemetrySdk;
import io.opentelemetry.sdk.autoconfigure.AutoConfiguredOpenTelemetrySdk;

import java.io.UnsupportedEncodingException;
import java.net.URLDecoder;
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
    // A service.name in OTEL_RESOURCE_ATTRIBUTES is the operator's choice too, but autoconfigure lets
    // otel.service.name win over it: don't supply the default name then.
    String fromResource = resourceServiceName(Diagnostics.config("otel.resource.attributes"));
    if (!fromResource.isEmpty()) props.remove("otel.service.name");
    Map<String, String> forced = new HashMap<>();
    if (overrides != null) {
      for (Map.Entry<?, ?> e : overrides.entrySet()) {
        if (e.getKey() != null && e.getValue() != null && !String.valueOf(e.getValue()).isEmpty()) {
          forced.put(String.valueOf(e.getKey()), String.valueOf(e.getValue()));
        }
      }
    }
    // otel.sdk.disabled: autoconfigure would hand back an SDK that makes spans and exports nothing, which
    // looks like a working fallback. Say what is going on instead.
    if ("true".equalsIgnoreCase(Diagnostics.config("otel.sdk.disabled"))) {
      r.put("started", false);
      r.put("serviceName", "");
      r.put("error", "the OpenTelemetry SDK is disabled (OTEL_SDK_DISABLED / otel.sdk.disabled is true)");
      return r;
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
        : !configured.isEmpty() ? configured
        : !fromResource.isEmpty() ? fromResource : props.getOrDefault("otel.service.name", "");
    r.put("started", true);
    r.put("serviceName", name);
    r.put("sdk", sdk);
    return r;
  }

  /** service.name from an otel.resource.attributes value ("k=v,k2=v2", values percent-encoded), else "". */
  static String resourceServiceName(String resourceAttributes) {
    String found = "";
    if (resourceAttributes == null) return found;
    for (String pair : resourceAttributes.split(",")) {
      int eq = pair.indexOf('=');
      if (eq <= 0 || !"service.name".equals(pair.substring(0, eq).trim())) continue;
      String v = pair.substring(eq + 1).trim();
      try {
        // as autoconfigure reads it: percent-decoded, with a literal "+" kept
        v = URLDecoder.decode(v.replace("+", "%2B"), "UTF-8");
      } catch (UnsupportedEncodingException | IllegalArgumentException ignored) {
        // not valid percent-encoding: keep the raw value
      }
      found = v;
    }
    return found;
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
