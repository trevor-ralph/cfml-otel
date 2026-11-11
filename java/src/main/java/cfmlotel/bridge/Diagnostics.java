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
  /** Files cfml-otel ships in lib/agent/ (build.sh), named in the warnings below. */
  static final String AGENT_EXTENSION_JAR = "cfml-otel-agent-extension.jar";
  static final String FR_MIXIN_BLACK_LIST = "fusionreactor-jdbc-mixin-blacklist.csv";

  private Diagnostics() {}

  /** Everything the checks look at. Plain fields so tests can build any combination. */
  static final class Facts {
    String engine = "";              // "lucee" | "acf" | "" (as passed by the CFML side)
    String apiVersion = "";          // opentelemetry-api on this application's classpath
    String apiPath = "";             // the jar (or directory) that opentelemetry-api was loaded from
    List<String> apiCopies = new ArrayList<>();   // every opentelemetry-api visible to the bridge's class loader
    String bridgePath = "";          // the jar the bridge was loaded from
    String bundledApiVersion = OtelBridge.BUNDLED_API_VERSION;
    String minApiVersion = OtelBridge.MIN_API_VERSION;
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
    // OTEL_* variables the container's main process (PID 1) has but this JVM doesn't: started through sudo or an
    // init script that drops the environment, so neither the agent nor the checks above see them
    List<String> envNotInherited = new ArrayList<>();
    boolean agentExtension;          // cfml-otel's agent extension is in otel.javaagent.extensions
    String frMixinBlackList = "";    // FusionReactor's -Dfr.mixin.black.list (a file of packages it leaves alone)
  }

  // ------------------------------------------------------------------------------------------
  // Gathering
  // ------------------------------------------------------------------------------------------

  static Facts gather(String engine, io.opentelemetry.api.OpenTelemetry otel, boolean sdkFallback) {
    Facts f = new Facts();
    f.engine = engine == null ? "" : engine.trim().toLowerCase(Locale.ROOT);
    f.apiVersion = apiVersion();
    f.apiPath = location(GlobalOpenTelemetry.class);
    f.bridgePath = location(OtelBridge.class);
    f.apiCopies = copies("io/opentelemetry/api/GlobalOpenTelemetry.class", OtelBridge.class.getClassLoader());
    f.implementation = otel.getClass().getName();
    f.agentBridged = OtelBridge.isAgentBridged();
    f.active = OtelBridge.isActiveFor(otel);
    f.sdkFallback = sdkFallback;
    // what the agent is configured with includes its configuration file; cfml-otel's own SDK never reads that
    f.config = sdkFallback ? Diagnostics::config : Diagnostics::agentConfig;
    f.agentExtension = f.config.apply("otel.javaagent.extensions").contains(AGENT_EXTENSION_JAR);
    String frBlackList = System.getProperty("fr.mixin.black.list");
    f.frMixinBlackList = frBlackList == null ? "" : frBlackList.trim();
    try {
      f.envNotInherited = envNotInherited(readEnviron(java.nio.file.Paths.get("/proc/1/environ")), System.getenv(),
          System.getProperties().stringPropertyNames());
    } catch (Throwable ignored) {
      // not Linux, or PID 1's environment isn't readable by this user: nothing to compare
    }

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

  private static volatile Map<String, String> agentConfigFile;

  /**
   * The javaagent's view of an OTel config value: {@link #config}, then the agent's configuration file
   * (-Dotel.javaagent.configuration-file / OTEL_JAVAAGENT_CONFIGURATION_FILE, a properties file), else "".
   */
  static String agentConfig(String key) {
    String v = config(key);
    if (!v.isEmpty()) return v;
    Map<String, String> file = agentConfigFile;
    if (file == null) {
      String path = config("otel.javaagent.configuration-file");
      file = path.isEmpty() ? Collections.<String, String>emptyMap() : readConfigFile(java.nio.file.Paths.get(path));
      agentConfigFile = file;
    }
    return fromConfigFile(file, key);
  }

  /** A javaagent configuration (properties) file, keys normalized as the agent does; empty if it can't be read. */
  static Map<String, String> readConfigFile(java.nio.file.Path file) {
    Map<String, String> out = new LinkedHashMap<>();
    try (InputStream in = java.nio.file.Files.newInputStream(file)) {
      Properties props = new Properties();
      props.load(in);
      for (String name : props.stringPropertyNames()) out.put(normalizeKey(name), props.getProperty(name).trim());
    } catch (Throwable ignored) {
      // unreadable: the agent says so itself
    }
    return out;
  }

  static String fromConfigFile(Map<String, String> file, String key) {
    String v = file.get(normalizeKey(key));
    return v == null ? "" : v;
  }

  /** The agent treats '-' and '_' in a property name like '.', and ignores case. */
  private static String normalizeKey(String key) {
    return key.toLowerCase(Locale.ROOT).replace('_', '.').replace('-', '.');
  }

  /** A /proc/<pid>/environ file (NUL-separated KEY=value); empty if it can't be read. */
  static Map<String, String> readEnviron(java.nio.file.Path file) {
    Map<String, String> env = new LinkedHashMap<>();
    try {
      String all = new String(java.nio.file.Files.readAllBytes(file), java.nio.charset.StandardCharsets.UTF_8);
      for (String kv : all.split("\u0000")) {
        int eq = kv.indexOf('=');
        if (eq > 0) env.put(kv.substring(0, eq), kv.substring(eq + 1));
      }
    } catch (Throwable ignored) {
      // unreadable
    }
    return env;
  }

  /**
   * OTEL_* names set in the other process's environment but in neither this JVM's environment nor its system
   * properties (OTEL_EXPORTER_OTLP_ENDPOINT also counts as set by -Dotel.exporter.otlp.endpoint).
   */
  static List<String> envNotInherited(Map<String, String> other, Map<String, String> own, Set<String> properties) {
    Set<String> props = new LinkedHashSet<>();
    for (String p : properties) props.add(p.toUpperCase(Locale.ROOT).replace('.', '_').replace('-', '_'));
    List<String> out = new ArrayList<>();
    for (String k : other.keySet()) {
      if (k.startsWith("OTEL_") && !own.containsKey(k) && !props.contains(k)) out.add(k);
    }
    Collections.sort(out);
    return out;
  }

  /** The jar (or classes directory) a class was loaded from, as a plain path; "" if unknown. */
  static String location(Class<?> c) {
    try {
      java.security.CodeSource cs = c.getProtectionDomain().getCodeSource();
      if (cs != null && cs.getLocation() != null) return path(cs.getLocation());
    } catch (Throwable ignored) {
      // fall through
    }
    // ACF's loadPaths class loader records no code source: ask the class loader where the class file is
    String resource = c.getName().replace('.', '/') + ".class";
    try {
      ClassLoader loader = c.getClassLoader() == null ? ClassLoader.getSystemClassLoader() : c.getClassLoader();
      java.net.URL url = loader.getResource(resource);
      if (url == null) return "";
      String p = path(url);
      return p.endsWith(resource) ? p.substring(0, p.length() - resource.length()) : p;
    } catch (Throwable e) {
      return "";
    }
  }

  /** Every jar (or directory) that provides a resource to this class loader, parents included. */
  static List<String> copies(String resource, ClassLoader loader) {
    List<String> out = new ArrayList<>();
    try {
      java.util.Enumeration<java.net.URL> e = (loader == null ? ClassLoader.getSystemClassLoader() : loader).getResources(resource);
      while (e.hasMoreElements()) {
        String p = path(e.nextElement());
        if (p.endsWith(resource)) p = p.substring(0, p.length() - resource.length());
        if (!p.isEmpty() && !out.contains(p)) out.add(p);
      }
    } catch (Throwable ignored) {
      // unknown: no duplicate warning
    }
    return out;
  }

  /** "/opt/lib/a.jar" for file:/opt/lib/a.jar and jar:file:/opt/lib/a.jar!/x/Y.class; else the URL's path. */
  static String path(java.net.URL url) {
    String s = url.toString();
    if (s.startsWith("jar:")) {
      s = s.substring(4);
      int bang = s.indexOf("!/");
      if (bang >= 0) s = s.substring(0, bang);
    }
    if (s.startsWith("file:")) {
      try {
        // normalized: ACF's classpath entries look like /opt/coldfusion/cfusion/bin/../lib/x.jar
        return java.nio.file.Paths.get(new java.net.URI(s)).normalize().toString().replace('\\', '/');
      } catch (Exception e) {
        return s.substring(5);
      }
    }
    return s;
  }

  /** The directory part of a path ("/opt/lib/" for "/opt/lib/a.jar"). */
  static String dir(String path) {
    String p = path == null ? "" : path.replace('\\', '/');
    if (p.endsWith("/")) p = p.substring(0, p.length() - 1);
    int slash = p.lastIndexOf('/');
    return slash < 0 ? "" : p.substring(0, slash + 1);
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
          + ", which bundles opentelemetry-api " + f.bundledApiVersion + " (" + tested + "). Parts of the API newer than"
          + " the agent may silently do nothing. Upgrade the agent, or rebuild lib/ with an API_VERSION it bundles."));
    }

    if (f.otelAgentPresent && !others.isEmpty()) {
      String msg = "Also attached alongside the OpenTelemetry javaagent: " + others
          + ". Two tracing agents can record the same requests twice and overwrite each other's trace headers on"
          + " outbound calls.";
      out.add(warning("warn", "OTHER_APM_AGENT", msg + " See the README section \"Running alongside other APM agents\"."));
    }
    boolean jdbcTraced = f.agentBridged && f.active && instrumentationOn(f.config, "jdbc");
    if (jdbcTraced && f.otherAgents.contains("FusionReactor") && f.frMixinBlackList.isEmpty()) {
      out.add(warning("warn", "FUSIONREACTOR_JDBC_MIXINS", "FusionReactor adds its own interfaces to JDBC driver"
          + " classes, which stops the OpenTelemetry javaagent instrumenting them: no database (cfquery / JDBC)"
          + " spans. Add -Dfr.mixin.black.list=<cfml-otel>/lib/agent/" + FR_MIXIN_BLACK_LIST + " to the JVM options"
          + " (it lists the JDBC driver packages for FusionReactor to leave alone; FusionReactor still records cfquery"
          + " through its ColdFusion integration). See the README section \"Running alongside other APM agents\"."));
    }
    if (jdbcTraced && "acf".equals(f.engine) && !f.agentExtension) {
      out.add(warning("warn", "ACF_JDBC_EXTENSION", "ColdFusion's built-in database drivers (jdbc:macromedia:... URLs)"
          + " are traced with db.system=other_sql and no server or database name unless the javaagent loads"
          + " cfml-otel's extension: add -Dotel.javaagent.extensions=<cfml-otel>/lib/agent/" + AGENT_EXTENSION_JAR
          + " to the JVM options. Ignore this if your datasources use other drivers, or if it is set in an agent"
          + " configuration file. See the README section \"Database queries (cfquery)\"."));
    }

    if (!f.envNotInherited.isEmpty() && (f.otelAgentPresent || f.sdkFallback)) {
      String msg = "These OTEL_* variables are set for the container (its main process) but didn't reach this JVM: "
          + String.join(", ", f.envNotInherited) + ". That happens when ColdFusion or Tomcat is started as a service"
          + " (sudo, an init script) that drops the environment, so " + (f.sdkFallback ? "cfml-otel's SDK" : "the agent")
          + " doesn't see them.";
      if (f.envNotInherited.contains("OTEL_EXPORTER_OTLP_ENDPOINT") && f.config.apply("otel.exporter.otlp.endpoint").isEmpty()) {
        msg += " Telemetry is going to the default endpoint, http://localhost:4318.";
      }
      out.add(warning("warn", "OTEL_ENV_NOT_INHERITED", msg + " Set them as -Dotel.* system properties in the JVM"
          + " options instead (ACF: jvm.config java.args; Lucee: setenv.sh), e.g."
          + " -Dotel.exporter.otlp.endpoint=http://collector:4318 -Dotel.service.name=myapp."));
    }

    // Which opentelemetry-api the bridge runs on: normally lib/'s copy, but a server can have its own (another library
    // in cfusion/lib or Tomcat's lib/ can depend on it)
    String api = "opentelemetry-api " + (f.apiVersion.isEmpty() ? "(unknown version)" : f.apiVersion)
        + (f.apiPath.isEmpty() ? "" : " from " + f.apiPath);
    if (f.apiCopies.size() > 1) {
      out.add(warning("warn", "DUPLICATE_OTEL_API", "opentelemetry-api is on this application's classpath "
          + f.apiCopies.size() + " times (" + String.join(", ", f.apiCopies) + "); " + api + " is the one in use."
          + " Mixed copies can fail in confusing ways. Keep one: where the server already has it (for example in"
          + " ACF's cfusion/lib), load only cfml-otel's bridge jar. See the README section \"Bridge-only install\"."));
    } else if (!f.apiPath.isEmpty() && !f.bridgePath.isEmpty() && !dir(f.apiPath).equals(dir(f.bridgePath))) {
      out.add(warning("info", "SERVER_OTEL_API", "cfml-otel is using the server's " + api + ", not the "
          + f.bundledApiVersion + " it ships in lib/. That works (a bridge-only install) for API "
          + f.minApiVersion + " and later, up to the version the javaagent bundles."));
    }
    if (olderThan(f.apiVersion, f.minApiVersion)) {
      out.add(warning("warn", "OTEL_API_TOO_OLD", "cfml-otel needs opentelemetry-api " + f.minApiVersion
          + " or later, but this application loaded " + api + ". Gauges and anything else newer fail with"
          + " NoClassDefFoundError / NoSuchMethodError. Upgrade that jar, or load cfml-otel's lib/ instead of it."));
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
    // cfhttp is Apache HttpClient 4 on both engines; the agent's module for it answers to both names
    return instrumentationOn(config, "apache-httpclient", "apache-httpclient-4.0");
  }

  /**
   * Whether the agent's instrumentation module with those names is on, by the agent's own rule: with
   * instrumentations on by default, any name set to false turns it off; with them off by default
   * (otel.instrumentation.common.default-enabled=false), any name set to true turns it on.
   */
  static boolean instrumentationOn(Function<String, String> config, String... names) {
    boolean defaultOn = !"false".equalsIgnoreCase(config.apply("otel.instrumentation.common.default-enabled"));
    boolean on = defaultOn;
    for (String name : names) {
      String specific = config.apply("otel.instrumentation." + name + ".enabled");
      boolean enabled = specific.isEmpty() ? defaultOn : !"false".equalsIgnoreCase(specific);
      if (defaultOn) on &= enabled;
      else on |= enabled;
    }
    return on;
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
    r.put("apiPath", f.apiPath);
    r.put("bundledApiVersion", f.bundledApiVersion);
    r.put("bridgeVersion", f.bridgeVersion);
    r.put("testedAgentVersion", f.testedAgentVersion);
    r.put("sdkFallback", f.sdkFallback);
    r.put("agentPresent", f.otelAgentPresent);
    r.put("agentVersion", f.otelAgentVersion);
    r.put("agentPath", f.otelAgentPath);
    r.put("jvmAgents", new ArrayList<>(f.jvmAgents));
    r.put("otherAgents", new ArrayList<>(f.otherAgents));
    r.put("agentExtension", f.agentExtension);
    r.put("warnings", evaluate(f));
    return r;
  }
}
