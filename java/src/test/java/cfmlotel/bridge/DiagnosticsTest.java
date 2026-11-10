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
    List<Map<String, String>> w = Diagnostics.evaluate(f);
    assertEquals(List.of("OTHER_APM_AGENT"), codes(f));
    assertTrue(w.get(0).get("message").contains("FusionReactor, New Relic"));
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
}
