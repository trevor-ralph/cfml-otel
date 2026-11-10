package cfmlotel.bridge;

import io.opentelemetry.sdk.common.CompletableResultCode;
import io.opentelemetry.sdk.common.export.Compressor;
import io.opentelemetry.sdk.common.export.HttpResponse;
import io.opentelemetry.sdk.common.export.HttpSender;
import io.opentelemetry.sdk.common.export.HttpSenderConfig;
import io.opentelemetry.sdk.common.export.MessageWriter;
import io.opentelemetry.sdk.common.export.RetryPolicy;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.ConnectException;
import java.net.HttpURLConnection;
import java.net.Proxy;
import java.net.ProxySelector;
import java.net.SocketTimeoutException;
import java.net.URI;
import java.time.Duration;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.TimeUnit;
import java.util.function.Consumer;
import java.util.function.Predicate;
import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLContext;

/**
 * OTLP/HTTP sender on {@link HttpURLConnection} for the SDK fallback. The SDK's own senders need
 * java.net.http (absent from Adobe ColdFusion's trimmed Java runtime) or OkHttp + Kotlin jars; this needs
 * nothing beyond java.base. Honours the exporter's endpoint, headers, compression, timeouts, TLS context,
 * proxy and retry policy.
 */
final class UrlConnectionHttpSender implements HttpSender {

  /** Retried per the OTLP spec. */
  private static final Set<Integer> RETRYABLE_STATUS = new HashSet<>(Arrays.asList(429, 502, 503, 504));

  private final HttpSenderConfig config;
  private final ExecutorService executor;
  private final boolean ownExecutor;

  UrlConnectionHttpSender(HttpSenderConfig config) {
    this.config = config;
    ExecutorService given = config.getExecutorService();
    this.ownExecutor = given == null;
    this.executor = given != null ? given : Executors.newSingleThreadExecutor(r -> {
      Thread t = new Thread(r, "cfml-otel-otlp-http");
      t.setDaemon(true);
      return t;
    });
  }

  @Override
  public void send(MessageWriter writer, Consumer<HttpResponse> onResponse, Consumer<Throwable> onError) {
    try {
      executor.execute(() -> {
        try {
          onResponse.accept(sendWithRetries(writer));
        } catch (Throwable t) {
          onError.accept(t);
        }
      });
    } catch (RuntimeException rejected) {
      onError.accept(rejected);
    }
  }

  private HttpResponse sendWithRetries(MessageWriter writer) throws IOException, InterruptedException {
    byte[] body = body(writer);
    RetryPolicy retry = config.getRetryPolicy();
    int attempts = retry == null ? 1 : Math.max(1, retry.getMaxAttempts());
    long backoffNanos = retry == null ? 0 : retry.getInitialBackoff().toNanos();
    for (int attempt = 1; ; attempt++) {
      try {
        Response r = sendOnce(body);
        if (attempt >= attempts || !RETRYABLE_STATUS.contains(r.statusCode)) return r;
      } catch (IOException e) {
        if (attempt >= attempts || !retryable(retry, e)) throw e;
      }
      long sleep = ThreadLocalRandom.current().nextLong(Math.max(1, backoffNanos));
      TimeUnit.NANOSECONDS.sleep(sleep);
      backoffNanos = Math.min((long) (backoffNanos * retry.getBackoffMultiplier()), retry.getMaxBackoff().toNanos());
    }
  }

  private static boolean retryable(RetryPolicy retry, IOException e) {
    Predicate<IOException> p = retry.getRetryExceptionPredicate();
    if (p != null) return p.test(e);
    return e instanceof ConnectException || e instanceof SocketTimeoutException;
  }

  private byte[] body(MessageWriter writer) throws IOException {
    ByteArrayOutputStream bytes = new ByteArrayOutputStream(Math.max(256, writer.getContentLength()));
    Compressor c = config.getCompressor();
    if (c == null) {
      writer.writeMessage(bytes);
    } else {
      try (OutputStream out = c.compress(bytes)) {
        writer.writeMessage(out);
      }
    }
    return bytes.toByteArray();
  }

  private Response sendOnce(byte[] body) throws IOException {
    URI endpoint = config.getEndpoint();
    HttpURLConnection conn = (HttpURLConnection) endpoint.toURL().openConnection(proxyFor(endpoint));
    try {
      SSLContext ssl = config.getSslContext();
      if (ssl != null && conn instanceof HttpsURLConnection) {
        ((HttpsURLConnection) conn).setSSLSocketFactory(ssl.getSocketFactory());
      }
      conn.setRequestMethod("POST");
      conn.setDoOutput(true);
      conn.setUseCaches(false);
      conn.setConnectTimeout(millis(config.getConnectTimeout()));
      conn.setReadTimeout(millis(config.getTimeout()));
      conn.setRequestProperty("Content-Type", config.getContentType());
      if (config.getCompressor() != null) conn.setRequestProperty("Content-Encoding", config.getCompressor().getEncoding());
      if (config.getHeadersSupplier() != null) {
        Map<String, List<String>> headers = config.getHeadersSupplier().get();
        if (headers != null) {
          for (Map.Entry<String, List<String>> h : headers.entrySet()) {
            for (String v : h.getValue()) conn.addRequestProperty(h.getKey(), v);
          }
        }
      }
      conn.setFixedLengthStreamingMode(body.length);
      try (OutputStream out = conn.getOutputStream()) {
        out.write(body);
      }
      int status = conn.getResponseCode();
      String message = conn.getResponseMessage();
      InputStream in = status >= 400 ? conn.getErrorStream() : conn.getInputStream();
      return new Response(status, message == null ? "" : message, read(in, config.getMaxResponseBodySize()));
    } catch (IOException | RuntimeException e) {
      // Only a failed exchange drops the connection. After a complete one (response read to the end and
      // closed) the JDK keeps it alive for the next export; disconnect() would close the socket every time.
      conn.disconnect();
      throw e;
    }
  }

  private Proxy proxyFor(URI endpoint) {
    if (config.getProxyOptions() == null) return Proxy.NO_PROXY;
    ProxySelector selector = config.getProxyOptions().getProxySelector();
    List<Proxy> proxies = selector == null ? null : selector.select(endpoint);
    return proxies == null || proxies.isEmpty() ? Proxy.NO_PROXY : proxies.get(0);
  }

  private static byte[] read(InputStream in, long max) throws IOException {
    if (in == null) return new byte[0];
    try (InputStream s = in) {
      ByteArrayOutputStream out = new ByteArrayOutputStream();
      byte[] buf = new byte[8192];
      long limit = max > 0 ? max : Long.MAX_VALUE;
      int n;
      while ((n = s.read(buf)) > 0 && out.size() < limit) out.write(buf, 0, (int) Math.min(n, limit - out.size()));
      return out.toByteArray();
    }
  }

  private static int millis(Duration d) {
    if (d == null) return 10_000;
    long ms = d.toMillis();
    return ms <= 0 ? 0 : (int) Math.min(Integer.MAX_VALUE, ms);
  }

  @Override
  public CompletableResultCode shutdown() {
    if (ownExecutor) executor.shutdown();
    return CompletableResultCode.ofSuccess();
  }

  private static final class Response implements HttpResponse {
    final int statusCode;
    final String message;
    final byte[] body;

    Response(int statusCode, String message, byte[] body) {
      this.statusCode = statusCode;
      this.message = message;
      this.body = body;
    }

    @Override
    public int getStatusCode() {
      return statusCode;
    }

    @Override
    public String getStatusMessage() {
      return message;
    }

    @Override
    public byte[] getResponseBody() {
      return body;
    }
  }
}
