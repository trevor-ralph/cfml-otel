package cfmlotel.bridge;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;

import java.util.Map;
import org.junit.jupiter.api.Test;

class HttpClientSemconvTest {

  @Test
  void basicGet() {
    Map<String, Object> a = HttpClientSemconv.attributes("get", "https://api.example.com/v1/orders?id=7");
    assertEquals("GET", a.get("http.request.method"));
    assertEquals("get", a.get("http.request.method_original"));
    assertEquals("api.example.com", a.get("server.address"));
    assertEquals(443L, a.get("server.port"));
    assertEquals("https://api.example.com/v1/orders?id=7", a.get("url.full"));
  }

  @Test
  void explicitPortAndPlainHttp() {
    Map<String, Object> a = HttpClientSemconv.attributes("POST", "http://127.0.0.1:8888/echo.cfm");
    assertEquals("POST", a.get("http.request.method"));
    assertFalse(a.containsKey("http.request.method_original"));
    assertEquals("127.0.0.1", a.get("server.address"));
    assertEquals(8888L, a.get("server.port"));
    assertEquals(80L, HttpClientSemconv.attributes("GET", "http://x.test/").get("server.port"));
  }

  @Test
  void unknownMethod() {
    Map<String, Object> a = HttpClientSemconv.attributes("PROPFIND", "http://x.test/");
    assertEquals("_OTHER", a.get("http.request.method"));
    assertEquals("PROPFIND", a.get("http.request.method_original"));
    assertEquals("HTTP", HttpClientSemconv.spanName("PROPFIND", ""));
  }

  @Test
  void ipv6AndUnencodedUrls() {
    assertEquals("::1", HttpClientSemconv.attributes("GET", "http://[::1]:8080/x").get("server.address"));
    Map<String, Object> a = HttpClientSemconv.attributes("GET", "http://legacy.test:81/search?q=two words");
    assertEquals("legacy.test", a.get("server.address"));
    assertEquals(81L, a.get("server.port"));
  }

  @Test
  void credentialsAndSignaturesAreRedacted() {
    assertEquals("https://REDACTED:REDACTED@host.test/p",
        HttpClientSemconv.redact("https://bob:s3cret@host.test/p"));
    assertEquals("https://host.test/f?X-Goog-Signature=REDACTED&x=1&sig=REDACTED#frag",
        HttpClientSemconv.redact("https://host.test/f?X-Goog-Signature=abc&x=1&sig=def#frag"));
    assertEquals("https://host.test/a@b", HttpClientSemconv.redact("https://host.test/a@b"));
    assertEquals("REDACTED:REDACTED@",
        HttpClientSemconv.attributes("GET", "http://u:p@h.test/").get("url.full").toString().substring(7, 25));
  }

  @Test
  void queryStringsAreRedactedOnTheirOwn() {
    assertEquals("file=x&Signature=REDACTED&AWSAccessKeyId=REDACTED&n=",
        HttpClientSemconv.redactQuery("file=x&Signature=abc123&AWSAccessKeyId=AKIAEXAMPLE&n="));
    assertEquals("a=1&flag", HttpClientSemconv.redactQuery("a=1&flag"));
    assertEquals("", HttpClientSemconv.redactQuery(""));
    assertEquals("", HttpClientSemconv.redactQuery(null));
  }

  @Test
  void unusablePortsAreLeftOffInsteadOfThrowing() {
    Map<String, Object> a = HttpClientSemconv.attributes("GET", "http://host.test:99999999999/x");
    assertEquals("host.test", a.get("server.address"));
    assertEquals(null, a.get("server.port"));
    assertEquals(null, HttpClientSemconv.attributes("GET", "http://host.test:70000/x y").get("server.port"));
  }

  @Test
  void spanNames() {
    assertEquals("GET", HttpClientSemconv.spanName("get", null));
    assertEquals("POST /orders/{id}", HttpClientSemconv.spanName("post", "/orders/{id}"));
  }

  @Test
  void statusCodes() {
    assertEquals(200, HttpClientSemconv.statusCode("200 OK"));
    assertEquals(404, HttpClientSemconv.statusCode("404 Not Found"));
    assertEquals(503, HttpClientSemconv.statusCode(503.0));
    assertEquals(0, HttpClientSemconv.statusCode("Connection Failure. Status code unavailable."));
    assertEquals(0, HttpClientSemconv.statusCode(""));
    assertEquals(0, HttpClientSemconv.statusCode(null));
  }
}
