package cfmlotel.bridge;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.sun.net.httpserver.HttpServer;
import io.opentelemetry.exporter.otlp.http.trace.OtlpHttpSpanExporter;
import io.opentelemetry.sdk.OpenTelemetrySdk;
import io.opentelemetry.sdk.common.export.Compressor;
import io.opentelemetry.sdk.common.export.HttpResponse;
import io.opentelemetry.sdk.common.export.HttpSenderConfig;
import io.opentelemetry.sdk.common.export.MessageWriter;
import io.opentelemetry.sdk.common.export.ProxyOptions;
import io.opentelemetry.sdk.common.export.RetryPolicy;
import io.opentelemetry.sdk.trace.SdkTracerProvider;
import io.opentelemetry.sdk.trace.export.SimpleSpanProcessor;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Supplier;
import java.util.zip.GZIPInputStream;
import java.util.zip.GZIPOutputStream;
import javax.net.ssl.SSLContext;
import javax.net.ssl.X509TrustManager;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

class UrlConnectionHttpSenderTest {

  private HttpServer server;
  private final ConcurrentLinkedQueue<Map<String, String>> requests = new ConcurrentLinkedQueue<>();
  private final AtomicInteger failFirst = new AtomicInteger();

  @BeforeEach
  void start() throws Exception {
    server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
    server.createContext("/", ex -> {
      byte[] raw;
      try (InputStream in = ex.getRequestBody()) {
        raw = in.readAllBytes();
      }
      String enc = ex.getRequestHeaders().getFirst("Content-Encoding");
      byte[] body = "gzip".equals(enc) ? new GZIPInputStream(new java.io.ByteArrayInputStream(raw)).readAllBytes() : raw;
      requests.add(Map.of(
          "path", ex.getRequestURI().getPath(),
          "method", ex.getRequestMethod(),
          "type", String.valueOf(ex.getRequestHeaders().getFirst("Content-Type")),
          "auth", String.valueOf(ex.getRequestHeaders().getFirst("Authorization")),
          "encoding", String.valueOf(enc),
          "clientPort", String.valueOf(ex.getRemoteAddress().getPort()),
          "body", new String(body, StandardCharsets.ISO_8859_1)));
      int status = failFirst.getAndDecrement() > 0 ? 503 : 200;
      byte[] reply = "ok".getBytes(StandardCharsets.UTF_8);
      ex.sendResponseHeaders(status, reply.length);
      try (OutputStream out = ex.getResponseBody()) {
        out.write(reply);
      }
    });
    server.start();
  }

  @AfterEach
  void stop() {
    server.stop(0);
  }

  private URI endpoint(String path) {
    return URI.create("http://127.0.0.1:" + server.getAddress().getPort() + path);
  }

  private HttpSenderConfig config(URI endpoint, Compressor compressor, RetryPolicy retry) {
    return new HttpSenderConfig() {
      @Override public URI getEndpoint() { return endpoint; }
      @Override public String getContentType() { return "application/x-protobuf"; }
      @Override public Compressor getCompressor() { return compressor; }
      @Override public Duration getTimeout() { return Duration.ofSeconds(5); }
      @Override public Duration getConnectTimeout() { return Duration.ofSeconds(5); }
      @Override public Supplier<Map<String, List<String>>> getHeadersSupplier() {
        return () -> Map.of("Authorization", List.of("Bearer test"));
      }
      @Override public ProxyOptions getProxyOptions() { return null; }
      @Override public RetryPolicy getRetryPolicy() { return retry; }
      @Override public SSLContext getSslContext() { return null; }
      @Override public X509TrustManager getTrustManager() { return null; }
      @Override public ExecutorService getExecutorService() { return null; }
    };
  }

  private static MessageWriter message(String text) {
    byte[] b = text.getBytes(StandardCharsets.ISO_8859_1);
    return new MessageWriter() {
      @Override public void writeMessage(OutputStream out) throws java.io.IOException { out.write(b); }
      @Override public int getContentLength() { return b.length; }
    };
  }

  private static HttpResponse send(UrlConnectionHttpSender sender, MessageWriter m) throws Exception {
    CompletableFuture<HttpResponse> f = new CompletableFuture<>();
    sender.send(m, f::complete, f::completeExceptionally);
    return f.get(20, TimeUnit.SECONDS);
  }

  @Test
  void postsBodyWithHeaders() throws Exception {
    UrlConnectionHttpSender s = new UrlConnectionHttpSender(config(endpoint("/v1/traces"), null, null));
    HttpResponse r = send(s, message("payload"));
    assertEquals(200, r.getStatusCode());
    assertEquals("ok", new String(r.getResponseBody(), StandardCharsets.UTF_8));
    Map<String, String> req = requests.poll();
    assertEquals("POST", req.get("method"));
    assertEquals("/v1/traces", req.get("path"));
    assertEquals("application/x-protobuf", req.get("type"));
    assertEquals("Bearer test", req.get("auth"));
    assertEquals("payload", req.get("body"));
    s.shutdown();
  }

  @Test
  void connectionIsKeptAliveBetweenExports() throws Exception {
    UrlConnectionHttpSender s = new UrlConnectionHttpSender(config(endpoint("/v1/traces"), null, null));
    for (int i = 0; i < 3; i++) assertEquals(200, send(s, message("batch " + i)).getStatusCode());
    // one client port = one TCP connection for all three exports
    assertEquals(1, requests.stream().map(r -> r.get("clientPort")).distinct().count(), requests.toString());
    s.shutdown();
  }

  @Test
  void gzipCompression() throws Exception {
    Compressor gzip = new Compressor() {
      @Override public String getEncoding() { return "gzip"; }
      @Override public OutputStream compress(OutputStream out) throws java.io.IOException { return new GZIPOutputStream(out); }
    };
    UrlConnectionHttpSender s = new UrlConnectionHttpSender(config(endpoint("/v1/logs"), gzip, null));
    assertEquals(200, send(s, message("compressed payload")).getStatusCode());
    Map<String, String> req = requests.poll();
    assertEquals("gzip", req.get("encoding"));
    assertEquals("compressed payload", req.get("body"));
  }

  @Test
  void retriesRetryableStatus() throws Exception {
    failFirst.set(2);
    RetryPolicy retry = RetryPolicy.builder().setMaxAttempts(3).setInitialBackoff(Duration.ofMillis(10)).build();
    UrlConnectionHttpSender s = new UrlConnectionHttpSender(config(endpoint("/v1/metrics"), null, retry));
    assertEquals(200, send(s, message("m")).getStatusCode());
    assertEquals(3, requests.size());
  }

  @Test
  void returnsTheLastRetryableStatusWhenAttemptsRunOut() throws Exception {
    failFirst.set(5);
    RetryPolicy retry = RetryPolicy.builder().setMaxAttempts(2).setInitialBackoff(Duration.ofMillis(10)).build();
    UrlConnectionHttpSender s = new UrlConnectionHttpSender(config(endpoint("/v1/metrics"), null, retry));
    assertEquals(503, send(s, message("m")).getStatusCode());
    assertEquals(2, requests.size());
  }

  @Test
  void connectionFailureReachesOnError() {
    UrlConnectionHttpSender s = new UrlConnectionHttpSender(config(URI.create("http://127.0.0.1:1/v1/traces"), null, null));
    CompletableFuture<HttpResponse> f = new CompletableFuture<>();
    s.send(message("x"), f::complete, f::completeExceptionally);
    try {
      f.get(20, TimeUnit.SECONDS);
    } catch (Exception e) {
      assertTrue(e.getCause() instanceof java.io.IOException, String.valueOf(e.getCause()));
      return;
    }
    throw new AssertionError("expected a connection error");
  }

  /** The real OTLP exporter finds this sender through META-INF/services and delivers a span. */
  @Test
  void otlpExporterUsesThisSender() {
    OtlpHttpSpanExporter exporter = OtlpHttpSpanExporter.builder().setEndpoint(endpoint("/v1/traces").toString()).build();
    OpenTelemetrySdk sdk = OpenTelemetrySdk.builder()
        .setTracerProvider(SdkTracerProvider.builder().addSpanProcessor(SimpleSpanProcessor.create(exporter)).build())
        .build();
    sdk.getTracer("test").spanBuilder("exported-span").startSpan().end();
    sdk.getSdkTracerProvider().forceFlush().join(10, TimeUnit.SECONDS);
    sdk.shutdown().join(10, TimeUnit.SECONDS);
    Map<String, String> req = requests.poll();
    assertEquals("/v1/traces", req.get("path"));
    assertEquals("application/x-protobuf", req.get("type"));
    assertTrue(req.get("body").contains("exported-span"), "span name in the protobuf payload");
  }

  @SuppressWarnings("unused")
  private static byte[] gzip(byte[] b) throws java.io.IOException {
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    try (GZIPOutputStream g = new GZIPOutputStream(out)) {
      g.write(b);
    }
    return out.toByteArray();
  }
}
