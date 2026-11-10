package cfmlotel.bridge;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;
import org.junit.jupiter.api.Test;

/** The startup checks for JVM setups the integration stack doesn't run (no agent, old agent, other APMs). */
class DiagnosticsTest {

  private static Diagnostics.Facts healthy(String engine) {
    Diagnostics.Facts f = new Diagnostics.Facts();
    f.engine = engine;
    f.apiVersion = "1.67.0";
    f.testedAgentVersion = "2.33.1";
    f.otelAgentPresent = true;
    f.otelAgentVersion = "2.33.1";
    f.agentBridged = true;
    f.active = true;
    f.implementation = "io.opentelemetry.javaagent.instrumentation.opentelemetryapi.ApplicationOpenTelemetry";
    f.agentExtension = true;
    return f;
  }

  private static Diagnostics.Facts withConfig(Diagnostics.Facts f, String... kv) {
    Map<String, String> m = new HashMap<>();
    for (int i = 0; i < kv.length; i += 2) m.put(kv[i], kv[i + 1]);
    f.config = k -> m.getOrDefault(k, "");
    return f;
  }

  private static List<String> codes(Diagnostics.Facts f) {
    return Diagnostics.evaluate(f).stream().map(w -> w.get("code")).collect(Collectors.toList());
  }

  @Test
  void healthyAcfHasNoWarnings() {
    assertEquals(List.of(), codes(healthy("acf")));
  }

  @Test
  void healthyLuceeWithHttpClientDisabledHasNoWarnings() {
    assertEquals(List.of(), codes(withConfig(healthy("lucee"), "otel.instrumentation.apache-httpclient.enabled", "false")));
  }

  @Test
  void luceeWithHttpClientInstrumentationOnIsWarned() {
    assertEquals(List.of("LUCEE_HTTPCLIENT_INSTRUMENTATION"), codes(healthy("lucee")));
    assertEquals(List.of("LUCEE_HTTPCLIENT_INSTRUMENTATION"),
        codes(withConfig(healthy("lucee"), "otel.instrumentation.apache-httpclient.enabled", "true")));
  }

  @Test
  void luceeWithAllInstrumentationOffByDefaultIsNotWarned() {
    assertEquals(List.of(), codes(withConfig(healthy("lucee"), "otel.instrumentation.common.default-enabled", "false")));
  }

  @Test
  void noAgentAtAll() {
    Diagnostics.Facts f = healthy("acf");
    f.otelAgentPresent = false;
    f.otelAgentVersion = "";
    f.agentBridged = false;
    f.active = false;
    assertEquals(List.of("NO_OTEL_AGENT"), codes(f));
  }

  @Test
  void otherApmOnlyNamesItInTheNoAgentWarning() {
    Diagnostics.Facts f = healthy("acf");
    f.otelAgentPresent = false;
    f.agentBridged = false;
    f.active = false;
    f.otherAgents.add("FusionReactor");
    List<Map<String, String>> w = Diagnostics.evaluate(f);
    assertEquals(1, w.size());
    assertEquals("NO_OTEL_AGENT", w.get(0).get("code"));
    assertTrue(w.get(0).get("message").contains("FusionReactor"));
  }

  @Test
  void agentThatDidNotBridgeTheApi() {
    Diagnostics.Facts f = healthy("acf");
    f.otelAgentVersion = "1.32.0";
    f.agentBridged = false;
    f.active = false;
    List<Map<String, String>> w = Diagnostics.evaluate(f);
    assertEquals(List.of("AGENT_NOT_BRIDGED"), codes(f));
    assertTrue(w.get(0).get("message").contains("1.32.0"));
    assertTrue(w.get(0).get("message").contains("1.67.0"));
  }

  @Test
  void disabledAgentIsNamedAsSuch() {
    Diagnostics.Facts f = withConfig(healthy("acf"), "otel.javaagent.enabled", "false");
    f.agentBridged = false;
    f.active = false;
    assertTrue(Diagnostics.evaluate(f).get(0).get("message").contains("otel.javaagent.enabled=false"));
  }

  @Test
  void bridgedButSdkDisabled() {
    Diagnostics.Facts f = withConfig(healthy("acf"), "otel.sdk.disabled", "true");
    f.active = false;
    assertEquals(List.of("SDK_DISABLED"), codes(f));
  }

  @Test
  void anotherImplementationOwnsGlobalOpenTelemetry() {
    Diagnostics.Facts f = healthy("acf");
    f.agentBridged = false;
    f.implementation = "io.opentelemetry.sdk.OpenTelemetrySdk";
    assertEquals(List.of("OTHER_IMPLEMENTATION"), codes(f));
    assertEquals("info", Diagnostics.evaluate(f).get(0).get("level"));
  }

  @Test
  void agentOlderThanTested() {
    Diagnostics.Facts f = healthy("acf");
    f.otelAgentVersion = "2.20.0";
    assertEquals(List.of("AGENT_OLDER_THAN_TESTED"), codes(f));
    f.otelAgentVersion = "2.40.0";
    assertEquals(List.of(), codes(f));
    f.otelAgentVersion = "";   // unknown (distribution without a manifest version): no guess
    assertEquals(List.of(), codes(f));
  }

  @Test
  void otherApmAlongsideTheAgent() {
    Diagnostics.Facts f = healthy("acf");
    f.otherAgents.add("FusionReactor");
    f.otherAgents.add("New Relic");
    f.frMixinBlackList = "/opt/cfml-otel/lib/agent/fusionreactor-jdbc-mixin-blacklist.csv";
    List<Map<String, String>> w = Diagnostics.evaluate(f);
    assertEquals(List.of("OTHER_APM_AGENT"), codes(f));
    assertTrue(w.get(0).get("message").contains("FusionReactor, New Relic"));
  }

  @Test
  void fusionReactorWithoutTheMixinBlackListLosesDatabaseSpans() {
    Diagnostics.Facts f = healthy("acf");
    f.otherAgents.add("FusionReactor");
    List<Map<String, String>> w = Diagnostics.evaluate(f);
    assertEquals(List.of("OTHER_APM_AGENT", "FUSIONREACTOR_JDBC_MIXINS"), codes(f));
    assertTrue(w.get(1).get("message").contains("-Dfr.mixin.black.list=<cfml-otel>/lib/agent/fusionreactor-jdbc-mixin-blacklist.csv"));
    f.frMixinBlackList = "/opt/cfml-otel/lib/agent/fusionreactor-jdbc-mixin-blacklist.csv";
    assertEquals(List.of("OTHER_APM_AGENT"), codes(f));
  }

  @Test
  void fusionReactorMixinsDontMatterWithJdbcInstrumentationOff() {
    Diagnostics.Facts f = withConfig(healthy("acf"), "otel.instrumentation.jdbc.enabled", "false");
    f.otherAgents.add("FusionReactor");
    assertEquals(List.of("OTHER_APM_AGENT"), codes(f));
  }

  @Test
  void acfWithoutTheAgentExtension() {
    Diagnostics.Facts f = healthy("acf");
    f.agentExtension = false;
    List<Map<String, String>> w = Diagnostics.evaluate(f);
    assertEquals(List.of("ACF_JDBC_EXTENSION"), codes(f));
    assertTrue(w.get(0).get("message").contains("-Dotel.javaagent.extensions=<cfml-otel>/lib/agent/cfml-otel-agent-extension.jar"));
    // only ACF has the macromedia drivers; and nothing to say when JDBC isn't traced anyway
    f.engine = "lucee";
    assertEquals(List.of("LUCEE_HTTPCLIENT_INSTRUMENTATION"), codes(f));
    assertEquals(List.of(), codes(withConfig(healthy("acf"), "otel.instrumentation.common.default-enabled", "false")));
  }

  @Test
  void agentPathParsing() {
    assertEquals("/otel/opentelemetry-javaagent.jar", Diagnostics.agentPath("-javaagent:/otel/opentelemetry-javaagent.jar"));
    assertEquals("/opt/fr/fusionreactor.jar", Diagnostics.agentPath("-javaagent:/opt/fr/fusionreactor.jar=name=x,address=8088"));
    assertEquals("C:\\fr\\fusionreactor.jar", Diagnostics.agentPath("-javaagent:\"C:\\fr\\fusionreactor.jar\""));
    assertEquals("/opt/dt/liboneagentloader.so", Diagnostics.agentPath("-agentpath:/opt/dt/liboneagentloader.so=seed"));
    assertEquals("", Diagnostics.agentPath("-Xmx512m"));
    assertEquals("", Diagnostics.agentPath("-agentlib:jdwp=transport=dt_socket"));
  }

  @Test
  void knownAgents() {
    assertEquals("FusionReactor", Diagnostics.knownAgent("/opt/fusionreactor/instance/cf/fusionreactor.jar"));
    assertEquals("FusionReactor", Diagnostics.knownAgent("C:\\FusionReactor\\instance\\cf\\fusionreactor.jar"));
    assertEquals("New Relic", Diagnostics.knownAgent("/opt/newrelic/newrelic.jar"));
    assertEquals("Datadog", Diagnostics.knownAgent("/dd/dd-java-agent.jar"));
    assertEquals("Elastic APM", Diagnostics.knownAgent("/x/elastic-apm-agent-1.50.0.jar"));
    assertEquals("AppDynamics", Diagnostics.knownAgent("/opt/AppServerAgent/javaagent.jar"));
    assertEquals("Dynatrace", Diagnostics.knownAgent("/opt/dynatrace/oneagent/agent/lib64/liboneagentloader.so"));
    assertEquals("SeeFusion", Diagnostics.knownAgent("/cf/lib/seefusion5.jar"));
    assertNull(Diagnostics.knownAgent("/otel/opentelemetry-javaagent.jar"));
    assertNull(Diagnostics.knownAgent("/opt/app/jmx_prometheus_javaagent.jar"));
  }

  @Test
  void versionComparison() {
    assertTrue(Diagnostics.olderThan("2.9.0", "2.33.1"));
    assertTrue(Diagnostics.olderThan("2.33.0", "2.33.1"));
    assertFalse(Diagnostics.olderThan("2.33.1", "2.33.1"));
    assertFalse(Diagnostics.olderThan("3.0.0", "2.33.1"));
    assertFalse(Diagnostics.olderThan("2.33", "2.33.1"));
    assertFalse(Diagnostics.olderThan("weird", "2.33.1"));
    assertTrue(Diagnostics.olderThan("2.20.0-alpha", "2.33.1"));
  }

  @Test
  void reportIsPlainData() {
    Map<String, Object> r = Diagnostics.report(healthy("acf"));
    assertEquals("1.67.0", r.get("apiVersion"));
    assertEquals(Boolean.TRUE, r.get("agentPresent"));
    assertTrue(r.get("warnings") instanceof List);
  }

  // ---- which opentelemetry-api the bridge runs on ----

  private static Diagnostics.Facts withApi(Diagnostics.Facts f, String version, String apiPath, String... copies) {
    f.apiVersion = version;
    f.apiPath = apiPath;
    f.bridgePath = "/app/cfml-otel/lib/cfml-otel-bridge-0.2.0.jar";
    f.apiCopies = List.of(copies);
    return f;
  }

  @Test
  void bundledApiNextToTheBridgeIsNotReported() {
    String api = "/app/cfml-otel/lib/opentelemetry-api-1.67.0.jar";
    assertEquals(List.of(), codes(withApi(healthy("acf"), "1.67.0", api, api)));
  }

  @Test
  void serverApiIsReportedAsInfo() {
    String api = "/opt/coldfusion/cfusion/lib/opentelemetry-api-1.45.0.jar";
    Diagnostics.Facts f = withApi(healthy("acf"), "1.45.0", api, api);
    assertEquals(List.of("SERVER_OTEL_API"), codes(f));
    Map<String, String> w = Diagnostics.evaluate(f).get(0);
    assertEquals("info", w.get("level"));
    assertTrue(w.get("message").contains("1.45.0 from " + api), w.get("message"));
  }

  @Test
  void twoApiCopiesAreWarned() {
    String server = "/opt/coldfusion/cfusion/lib/opentelemetry-api-1.45.0.jar";
    String ours = "/app/cfml-otel/lib/opentelemetry-api-1.67.0.jar";
    Diagnostics.Facts f = withApi(healthy("acf"), "1.45.0", server, server, ours);
    assertEquals(List.of("DUPLICATE_OTEL_API"), codes(f));
    String msg = Diagnostics.evaluate(f).get(0).get("message");
    assertTrue(msg.contains("2 times") && msg.contains(server) && msg.contains(ours) && msg.contains("Bridge-only install"), msg);
  }

  @Test
  void apiOlderThanTheMinimumIsWarned() {
    String api = "/opt/coldfusion/cfusion/lib/opentelemetry-api-1.37.0.jar";
    assertEquals(List.of("SERVER_OTEL_API", "OTEL_API_TOO_OLD"), codes(withApi(healthy("acf"), "1.37.0", api, api)));
    assertEquals(List.of(), codes(withApi(healthy("acf"), OtelBridge.MIN_API_VERSION,
        "/app/cfml-otel/lib/opentelemetry-api.jar", "/app/cfml-otel/lib/opentelemetry-api.jar")));
  }

  @Test
  void onlyFusionReactorGetsTheDatabaseSpanWarning() {
    Diagnostics.Facts f = healthy("acf");
    f.otherAgents.add("FusionReactor");
    String msg = Diagnostics.evaluate(f).get(1).get("message");
    assertTrue(msg.contains("database") && msg.contains("FusionReactor"), msg);
    f.otherAgents.set(0, "Datadog");
    assertEquals(List.of("OTHER_APM_AGENT"), codes(f));
    assertFalse(Diagnostics.evaluate(f).get(0).get("message").contains("database"));
  }

  @Test
  void locationHelpers() throws Exception {
    assertEquals("/opt/lib/a.jar", Diagnostics.path(new java.net.URL("jar:file:/opt/lib/a.jar!/io/x/Y.class")));
    assertEquals("/opt/lib/a.jar", Diagnostics.path(new java.net.URL("file:/opt/lib/a.jar")));
    assertEquals("/opt/cf/lib/a.jar", Diagnostics.path(new java.net.URL("jar:file:/opt/cf/bin/../lib/a.jar!/io/x/Y.class")));
    // a class from a jar on the test classpath is located through its code source or, failing that, its .class resource
    assertTrue(Diagnostics.location(io.opentelemetry.api.GlobalOpenTelemetry.class).endsWith(".jar"), Diagnostics.location(io.opentelemetry.api.GlobalOpenTelemetry.class));
    assertEquals("/opt/lib/", Diagnostics.dir("/opt/lib/a.jar"));
    assertEquals("C:/cf/lib/", Diagnostics.dir("C:\\cf\\lib\\a.jar"));
    // the bridge's own API, from the test classpath: exactly one copy
    assertEquals(1, Diagnostics.copies("io/opentelemetry/api/GlobalOpenTelemetry.class", getClass().getClassLoader()).size());
  }

  // ---- OTEL_* variables that didn't reach the JVM (ACF started as a service through sudo) ----

  @Test
  void envNotInheritedComparesWithTheJvmEnvironmentAndSystemProperties() {
    Map<String, String> pid1 = Map.of("OTEL_EXPORTER_OTLP_ENDPOINT", "http://collector:4318", "OTEL_SERVICE_NAME", "shop",
        "OTEL_INSTRUMENTATION_APACHE_HTTPCLIENT_ENABLED", "false", "PATH", "/usr/bin");
    assertEquals(List.of("OTEL_EXPORTER_OTLP_ENDPOINT", "OTEL_INSTRUMENTATION_APACHE_HTTPCLIENT_ENABLED", "OTEL_SERVICE_NAME"),
        Diagnostics.envNotInherited(pid1, Map.of(), java.util.Set.of()));
    // inherited, or given as -D system properties (dots and dashes map to underscores): nothing to report
    assertEquals(List.of(), Diagnostics.envNotInherited(pid1, Map.of("OTEL_SERVICE_NAME", "shop"),
        java.util.Set.of("otel.exporter.otlp.endpoint", "otel.instrumentation.apache-httpclient.enabled")));
    assertEquals(List.of(), Diagnostics.envNotInherited(Map.of(), Map.of(), java.util.Set.of()));
  }

  @Test
  void readEnvironParsesNulSeparatedPairs() throws Exception {
    java.nio.file.Path tmp = java.nio.file.Files.createTempFile("environ", "");
    java.nio.file.Files.write(tmp, "A=1\u0000OTEL_SERVICE_NAME=a=b\u0000\u0000".getBytes(java.nio.charset.StandardCharsets.UTF_8));
    assertEquals(Map.of("A", "1", "OTEL_SERVICE_NAME", "a=b"), Diagnostics.readEnviron(tmp));
    java.nio.file.Files.delete(tmp);
    assertEquals(Map.of(), Diagnostics.readEnviron(tmp));
  }

  @Test
  void otelEnvThatDidNotReachTheJvmIsWarned() {
    Diagnostics.Facts f = healthy("acf");
    f.envNotInherited = List.of("OTEL_EXPORTER_OTLP_ENDPOINT", "OTEL_SERVICE_NAME");
    assertEquals(List.of("OTEL_ENV_NOT_INHERITED"), codes(f));
    String msg = Diagnostics.evaluate(f).get(0).get("message");
    assertTrue(msg.contains("http://localhost:4318") && msg.contains("-Dotel.exporter.otlp.endpoint"), msg);
    // the endpoint is set some other way: no claim about where telemetry goes
    msg = Diagnostics.evaluate(withConfig(f, "otel.exporter.otlp.endpoint", "http://x:4318")).get(0).get("message");
    assertFalse(msg.contains("localhost:4318"), msg);
    // nothing reads OTEL_* (no agent, no fallback): no warning
    Diagnostics.Facts none = new Diagnostics.Facts();
    none.envNotInherited = List.of("OTEL_SERVICE_NAME");
    assertFalse(codes(none).contains("OTEL_ENV_NOT_INHERITED"));
  }
}
