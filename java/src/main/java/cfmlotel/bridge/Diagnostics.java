package cfmlotel.bridge;

import io.opentelemetry.api.GlobalOpenTelemetry;

import java.io.InputStream;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Properties;
import java.util.Set;
import java.util.function.Function;

/**
 * Startup self-checks: what is attached to this JVM and whether cfml-otel can actually record anything.
 *
 * <p>{@link #gather} reads the environment into {@link Facts}; {@link #evaluate} turns facts into
 * warnings and is pure, so every case is unit-testable without a JVM set up that way.
 */
final class Diagnostics {

  /** Main class of the upstream javaagent (and of distributions built on it). */
  static final String OTEL_AGENT_CLASS = "io.opentelemetry.javaagent.OpenTelemetryAgent";

  private Diagnostics() {}

  /** Everything the checks look at. Plain fields so tests can build any combination. */
  static final class Facts {
    String engine = "";              // "lucee" | "acf" | "" (as passed by the CFML side)
    String apiVersion = "";          // opentelemetry-api on this application's classpath
    String bridgeVersion = OtelBridge.VERSION;
    String testedAgentVersion = OtelBridge.TESTED_AGENT_VERSION;
    boolean otelAgentPresent;        // the OTel javaagent's main class is loaded / on the JVM command line
    String otelAgentVersion = "";
    String otelAgentPath = "";
    List<String> jvmAgents = new ArrayList<>();   // every -javaagent / -agentpath on the JVM
    List<String> otherAgents = new ArrayList<>(); // recognised non-OTel APM agents, by product name
    boolean agentBridged;            // GlobalOpenTelemetry is the javaagent's bridge
    boolean active;                  // spans would be recorded
    boolean sdkFallback;             // cfml-otel's own SDK is the implementation
    String implementation = "";      // GlobalOpenTelemetry's class
    Function<String, String> config = k -> "";  // OTel config lookup (system property, then env var)
  }

  // ------------------------------------------------------------------------------------------
  // Gathering
  // ------------------------------------------------------------------------------------------

  static Facts gather(String engine, io.opentelemetry.api.OpenTelemetry otel, boolean sdkFallback) {
    Facts f = new Facts();
    f.engine = engine == null ? "" : engine.trim().toLowerCase(Locale.ROOT);
    f.apiVersion = apiVersion();
    f.implementation = otel.getClass().getName();
    f.agentBridged = OtelBridge.isAgentBridged();
    f.active = OtelBridge.isActiveFor(otel);
    f.sdkFallback = sdkFallback;
    f.config = Diagnostics::config;

    Set<String> args = new LinkedHashSet<>();
    try {
      args.addAll(java.lang.management.ManagementFactory.getRuntimeMXBean().getInputArguments());
    } catch (Throwable ignored) {
      // java.management missing (jlinked runtime) or restricted: the env vars below still help
    }
    for (String env : new String[] {"JAVA_TOOL_OPTIONS", "JDK_JAVA_OPTIONS"}) {
      String v = System.getenv(env);
      if (v != null) Collections.addAll(args, v.trim().split("\\s+"));
    }
    for (String a : args) {
      String path = agentPath(a);
      if (path.isEmpty() || f.jvmAgents.contains(path)) continue;
      f.jvmAgents.add(path);
      String product = knownAgent(path);
      if (product != null && !f.otherAgents.contains(product)) f.otherAgents.add(product);
      if (path.toLowerCase(Locale.ROOT).contains("opentelemetry-javaagent")) {
        f.otelAgentPresent = true;
        f.otelAgentPath = path;
      }
    }

    try {
      Class<?> agent = Class.forName(OTEL_AGENT_CLASS, false, ClassLoader.getSystemClassLoader());
      f.otelAgentPresent = true;
      Package p = agent.getPackage();
      if (p != null && p.getImplementationVersion() != null) f.otelAgentVersion = p.getImplementationVersion();
    } catch (Throwable ignored) {
      // not attached (or attached under another name: see the path check above)
    }
    if (f.agentBridged) f.otelAgentPresent = true;
    return f;
  }

  /** "/opt/x/agent.jar" for "-javaagent:/opt/x/agent.jar=opts" or "-agentpath:/lib/x.so=opts", else "". */
  static String agentPath(String arg) {
    if (arg == null) return "";
    String a = arg.trim();
    String rest;
    if (a.startsWith("-javaagent:")) rest = a.substring("-javaagent:".length());
    else if (a.startsWith("-agentpath:")) rest = a.substring("-agentpath:".length());
    else return "";
    int eq = rest.indexOf('=');
    String path = (eq >= 0 ? rest.substring(0, eq) : rest).trim();
    if (path.length() > 1 && (path.startsWith("\"") || path.startsWith("'"))) path = path.substring(1);
    if (path.endsWith("\"") || path.endsWith("'")) path = path.substring(0, path.length() - 1);
    return path;
  }

  /** Product name for a known non-OTel APM agent's jar / library path, else null. */
  static String knownAgent(String path) {
    String p = path.replace('\\', '/').toLowerCase(Locale.ROOT);
    String file = p.substring(p.lastIndexOf('/') + 1);
    if (p.contains("fusionreactor")) return "FusionReactor";
    if (p.contains("seefusion")) return "SeeFusion";
    if (file.startsWith("newrelic") || p.contains("/newrelic/")) return "New Relic";
    if (file.startsWith("dd-java-agent")) return "Datadog";
    if (file.startsWith("elastic-apm-agent")) return "Elastic APM";
    if (p.contains("appdynamics") || p.contains("appserveragent")) return "AppDynamics";
    if (p.contains("dynatrace") || p.contains("oneagent")) return "Dynatrace";
    if (file.startsWith("glowroot")) return "Glowroot";
    if (file.startsWith("skywalking-agent")) return "Apache SkyWalking";
    if (file.startsWith("pinpoint-bootstrap")) return "Pinpoint";
    return null;
  }

  /** OTel config value: system property (otel.x.y) first, then the env var (OTEL_X_Y), else "". */
  static String config(String key) {
    String v = System.getProperty(key);
    if (v == null) v = System.getenv(key.toUpperCase(Locale.ROOT).replace('.', '_').replace('-', '_'));
    return v == null ? "" : v.trim();
  }

  /** Version of the opentelemetry-api jar this application loaded. */
  static String apiVersion() {
    Package p = GlobalOpenTelemetry.class.getPackage();
    if (p != null && p.getImplementationVersion() != null) return p.getImplementationVersion();
    try (InputStream in = GlobalOpenTelemetry.class.getResourceAsStream("/io/opentelemetry/api/version.properties")) {
      if (in != null) {
        Properties props = new Properties();
        props.load(in);
        String v = props.getProperty("sdk.version");
        if (v != null) return v.trim();
      }
    } catch (Exception ignored) {
      // unknown
    }
    return "";
  }

  // ------------------------------------------------------------------------------------------
  // Evaluation
  // ------------------------------------------------------------------------------------------

  static List<Map<String, String>> evaluate(Facts f) {
    List<Map<String, String>> out = new ArrayList<>();
    String agentLabel = "OpenTelemetry javaagent" + (f.otelAgentVersion.isEmpty() ? "" : " " + f.otelAgentVersion);
    String tested = "cfml-otel " + f.bridgeVersion + " is tested with javaagent " + f.testedAgentVersion;
    String others = String.join(", ", f.otherAgents);

    if (!f.active && !f.otelAgentPresent) {
      String msg = "No OpenTelemetry javaagent is attached and no OpenTelemetry SDK is registered, so cfml-otel is a"
          + " no-op: nothing is recorded. Add -javaagent:/path/to/opentelemetry-javaagent.jar to the JVM options ("
          + tested + "), or turn on cfml-otel's sdkFallback (needs lib/sdk/ on the classpath).";
      if (!others.isEmpty()) {
        msg += " Also attached: " + others + ". It isn't registered as the OpenTelemetry implementation, so cfml-otel"
            + " can't report through it.";
      }
      out.add(warning("warn", "NO_OTEL_AGENT", msg));
    } else if (f.otelAgentPresent && !f.agentBridged && !f.active) {
      String msg = "The " + agentLabel + " is attached, but it did not bridge this application's opentelemetry-api "
          + f.apiVersion + ", so cfml-otel is a no-op. The agent only bridges API versions up to the one it bundles:"
          + " use a newer agent (" + tested + ") or rebuild lib/ with an older API_VERSION.";
      if ("false".equalsIgnoreCase(f.config.apply("otel.javaagent.enabled"))) {
        msg = "The OpenTelemetry javaagent is attached but disabled (otel.javaagent.enabled=false), so cfml-otel is"
            + " a no-op.";
      }
      out.add(warning("warn", "AGENT_NOT_BRIDGED", msg));
    } else if (f.agentBridged && !f.active) {
      out.add(warning("warn", "SDK_DISABLED", "The " + agentLabel + " bridged cfml-otel, but nothing is recorded:"
          + " its SDK is disabled" + ("true".equalsIgnoreCase(f.config.apply("otel.sdk.disabled"))
              ? " (otel.sdk.disabled=true)." : ".")));
    } else if (f.active && !f.agentBridged && f.otelAgentPresent) {
      out.add(warning("info", "OTHER_IMPLEMENTATION", "The OpenTelemetry javaagent is attached, but OpenTelemetry"
          + " is provided by " + f.implementation + ": cfml-otel's telemetry goes there, not to the agent."));
    }

    if (f.agentBridged && f.active && olderThan(f.otelAgentVersion, f.testedAgentVersion)) {
      out.add(warning("warn", "AGENT_OLDER_THAN_TESTED", "The " + agentLabel + " is older than " + f.testedAgentVersion
          + ", which bundles opentelemetry-api " + f.apiVersion + " (" + tested + "). Parts of the API newer than"
          + " the agent may silently do nothing. Upgrade the agent, or rebuild lib/ with an API_VERSION it bundles."));
    }

    if (f.otelAgentPresent && !others.isEmpty()) {
      out.add(warning("warn", "OTHER_APM_AGENT", "Also attached alongside the OpenTelemetry javaagent: " + others
          + ". Two tracing agents can record the same requests twice and overwrite each other's trace headers on"
          + " outbound calls. See the README section \"Running alongside other APM agents\"."));
    }

    if ("lucee".equals(f.engine) && f.agentBridged && f.active && httpClientInstrumentationOn(f.config)) {
      out.add(warning("warn", "LUCEE_HTTPCLIENT_INSTRUMENTATION", "On Lucee, set"
          + " OTEL_INSTRUMENTATION_APACHE_HTTPCLIENT_ENABLED=false (or -Dotel.instrumentation.apache-httpclient.enabled=false)."
          + " Lucee runs cfhttp on a worker thread, so the agent's HttpClient spans start orphan traces and overwrite"
          + " the traceparent header cfml-otel injects (LDEV-6519). Ignore this if it is already set in an agent"
          + " configuration file."));
    }
    return out;
  }

  static boolean httpClientInstrumentationOn(Function<String, String> config) {
    String specific = config.apply("otel.instrumentation.apache-httpclient.enabled");
    if (!specific.isEmpty()) return !"false".equalsIgnoreCase(specific);
    return !"false".equalsIgnoreCase(config.apply("otel.instrumentation.common.default-enabled"));
  }

  /** True only when both are plain x.y.z versions and a is older than b. */
  static boolean olderThan(String a, String b) {
    int[] x = parse(a);
    int[] y = parse(b);
    if (x == null || y == null) return false;
    for (int i = 0; i < 3; i++) {
      if (x[i] != y[i]) return x[i] < y[i];
    }
    return false;
  }

  private static int[] parse(String v) {
    if (v == null) return null;
    String[] parts = v.trim().split("[.-]");
    if (parts.length < 3) return null;
    int[] out = new int[3];
    try {
      for (int i = 0; i < 3; i++) out[i] = Integer.parseInt(parts[i]);
    } catch (NumberFormatException e) {
      return null;
    }
    return out;
  }

  private static Map<String, String> warning(String level, String code, String message) {
    Map<String, String> w = new LinkedHashMap<>();
    w.put("level", level);
    w.put("code", code);
    w.put("message", message);
    return w;
  }

  /** The facts plus warnings, as plain maps/lists/strings/booleans for CFML. */
  static Map<String, Object> report(Facts f) {
    Map<String, Object> r = new LinkedHashMap<>();
    r.put("apiVersion", f.apiVersion);
    r.put("bridgeVersion", f.bridgeVersion);
    r.put("testedAgentVersion", f.testedAgentVersion);
    r.put("sdkFallback", f.sdkFallback);
    r.put("agentPresent", f.otelAgentPresent);
    r.put("agentVersion", f.otelAgentVersion);
    r.put("agentPath", f.otelAgentPath);
    r.put("jvmAgents", new ArrayList<>(f.jvmAgents));
    r.put("otherAgents", new ArrayList<>(f.otherAgents));
    r.put("warnings", evaluate(f));
    return r;
  }
}
