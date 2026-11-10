package cfmlotel.bridge;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.HashMap;
import java.util.Map;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;

/** Which service.name the fallback SDK ends up with: explicit option, OTEL_* configuration, or the default. */
class SdkFallbackTest {

  private static final String[] PROPS = {"otel.resource.attributes", "otel.service.name", "otel.sdk.disabled"};

  private Object sdk;

  @AfterEach
  void cleanUp() {
    for (String p : PROPS) System.clearProperty(p);
    if (sdk != null) SdkFallback.shutdown(sdk);
  }

  /** Starts a fallback SDK that exports nothing; the app name default is "app-default". */
  private Map<String, Object> start(String serviceNameOption) {
    Map<String, String> overrides = new HashMap<>();
    for (String signal : new String[] {"traces", "metrics", "logs"}) overrides.put("otel." + signal + ".exporter", "none");
    if (serviceNameOption != null) overrides.put("otel.service.name", serviceNameOption);
    Map<String, Object> r = SdkFallback.start(Map.of("otel.service.name", "app-default"), overrides);
    assertEquals(true, r.get("started"), String.valueOf(r.get("error")));
    sdk = r.get("sdk");
    return r;
  }

  private void assertResourceServiceName(String expected) {
    // the SDK's toString() prints its resource; there is no public getter for it
    assertTrue(String.valueOf(sdk).contains("service.name=\"" + expected + "\""), String.valueOf(sdk));
  }

  @Test
  void resourceServiceNameIsParsedLikeAutoconfigureDoes() {
    assertEquals("billing", SdkFallback.resourceServiceName("service.name=billing,deployment.environment=prod"));
    assertEquals("billing", SdkFallback.resourceServiceName("deployment.environment=prod, service.name = billing "));
    assertEquals("my app+1", SdkFallback.resourceServiceName("service.name=my%20app+1"));
    assertEquals("", SdkFallback.resourceServiceName("service.namespace=shop,deployment.environment=prod"));
    assertEquals("", SdkFallback.resourceServiceName(""));
    assertEquals("", SdkFallback.resourceServiceName(null));
  }

  @Test
  void defaultNameAppliesWhenNothingIsConfigured() {
    assertEquals("app-default", start(null).get("serviceName"));
    assertResourceServiceName("app-default");
  }

  @Test
  void resourceAttributesServiceNameBeatsTheDefault() {
    System.setProperty("otel.resource.attributes", "service.name=billing,deployment.environment=prod");
    assertEquals("billing", start(null).get("serviceName"));
    assertResourceServiceName("billing");
  }

  @Test
  void otelServiceNameBeatsResourceAttributes() {
    System.setProperty("otel.resource.attributes", "service.name=billing");
    System.setProperty("otel.service.name", "from-service-name");
    assertEquals("from-service-name", start(null).get("serviceName"));
    assertResourceServiceName("from-service-name");
  }

  @Test
  void disabledSdkIsReportedAsNotStarted() {
    System.setProperty("otel.sdk.disabled", "true");
    int before = SdkFallback.liveCount();
    Map<String, Object> r = SdkFallback.start(Map.of("otel.service.name", "app-default"), Map.of());
    assertEquals(false, r.get("started"));
    assertTrue(String.valueOf(r.get("error")).contains("otel.sdk.disabled"), String.valueOf(r.get("error")));
    assertEquals(before, SdkFallback.liveCount());
  }

  @Test
  void serviceNameOptionBeatsEverything() {
    System.setProperty("otel.resource.attributes", "service.name=billing");
    System.setProperty("otel.service.name", "from-service-name");
    assertEquals("from-option", start("from-option").get("serviceName"));
    assertResourceServiceName("from-option");
  }
}
