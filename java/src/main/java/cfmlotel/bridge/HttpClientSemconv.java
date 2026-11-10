package cfmlotel.bridge;

import java.net.URI;
import java.util.Arrays;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * HTTP client span attributes per the stable OpenTelemetry HTTP semantic conventions, for outbound calls
 * cfml-otel traces itself (cfhttp on Lucee, or wherever the agent's own HttpClient spans are off).
 */
final class HttpClientSemconv {

  private HttpClientSemconv() {}

  static final Set<String> KNOWN_METHODS = new HashSet<>(Arrays.asList(
      "CONNECT", "DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT", "TRACE", "QUERY"));

  /** Query parameters whose values are always redacted from url.full (the semconv's default list). */
  static final Set<String> SENSITIVE_QUERY_PARAMS = new HashSet<>(Arrays.asList(
      "awsaccesskeyid", "signature", "sig", "x-goog-signature"));

  private static final Pattern LOOSE_URL = Pattern.compile("^([a-zA-Z][a-zA-Z0-9+.-]*)://(?:[^@/?#]*@)?(\\[[^\\]]+\\]|[^:/?#]+)(?::(\\d+))?");
  private static final Pattern STATUS = Pattern.compile("^\\s*(\\d{3})(?:\\D|$)");

  /** http.request.method (+ _original), server.address, server.port and url.full for a client call. */
  static Map<String, Object> attributes(String method, String url) {
    Map<String, Object> a = new LinkedHashMap<>();
    String m = method == null ? "" : method.trim();
    String upper = m.toUpperCase(Locale.ROOT);
    if (KNOWN_METHODS.contains(upper)) {
      a.put("http.request.method", upper);
      if (!m.equals(upper)) a.put("http.request.method_original", m);
    } else {
      a.put("http.request.method", "_OTHER");
      a.put("http.request.method_original", m);
    }

    String u = url == null ? "" : url.trim();
    String scheme = "";
    String host = "";
    int port = -1;
    try {
      URI uri = new URI(u);
      scheme = uri.getScheme() == null ? "" : uri.getScheme();
      host = uri.getHost() == null ? "" : uri.getHost();
      port = uri.getPort();
    } catch (Exception ignored) {
      // fall through to the lenient parse (unencoded spaces etc. are common in CFML URLs)
    }
    if (host.isEmpty()) {
      Matcher mm = LOOSE_URL.matcher(u);
      if (mm.find()) {
        scheme = mm.group(1);
        host = mm.group(2);
        if (mm.group(3) != null) {
          try {
            port = Integer.parseInt(mm.group(3));
          } catch (NumberFormatException tooLong) {
            port = Integer.MAX_VALUE;   // an unusable port, not a missing one: server.port is left off below
          }
        }
      }
    }
    if (host.startsWith("[") && host.endsWith("]")) host = host.substring(1, host.length() - 1);
    if (port < 0) {
      if ("https".equalsIgnoreCase(scheme)) port = 443;
      else if ("http".equalsIgnoreCase(scheme)) port = 80;
    }
    if (!host.isEmpty()) a.put("server.address", host);
    if (port > 0 && port <= 65535) a.put("server.port", (long) port);
    if (!u.isEmpty()) a.put("url.full", redact(u));
    return a;
  }

  /** Span name: "{method} {url.template}" when a template is given, else "{method}" (semconv). */
  static String spanName(String method, String urlTemplate) {
    String m = String.valueOf(attributes(method, "").get("http.request.method"));
    if ("_OTHER".equals(m)) m = "HTTP";
    return urlTemplate == null || urlTemplate.trim().isEmpty() ? m : m + " " + urlTemplate.trim();
  }

  /** Credentials in the authority become REDACTED:REDACTED; sensitive query parameter values become REDACTED. */
  static String redact(String url) {
    String out = url;
    int schemeEnd = out.indexOf("://");
    if (schemeEnd > 0) {
      int authStart = schemeEnd + 3;
      int authEnd = authStart;
      while (authEnd < out.length() && "/?#".indexOf(out.charAt(authEnd)) < 0) authEnd++;
      int at = out.lastIndexOf('@', authEnd - 1);
      if (at >= authStart) out = out.substring(0, authStart) + "REDACTED:REDACTED" + out.substring(at);
    }
    int q = out.indexOf('?');
    if (q < 0) return out;
    int hash = out.indexOf('#', q);
    String query = hash < 0 ? out.substring(q + 1) : out.substring(q + 1, hash);
    return out.substring(0, q + 1) + redactQuery(query) + (hash < 0 ? "" : out.substring(hash));
  }

  /** A query string (no leading "?") with the sensitive parameters' values replaced by REDACTED. */
  static String redactQuery(String query) {
    if (query == null || query.isEmpty()) return "";
    StringBuilder sb = new StringBuilder();
    boolean first = true;
    for (String pair : query.split("&", -1)) {
      if (!first) sb.append('&');
      first = false;
      int eq = pair.indexOf('=');
      String key = eq < 0 ? pair : pair.substring(0, eq);
      if (eq >= 0 && SENSITIVE_QUERY_PARAMS.contains(key.toLowerCase(Locale.ROOT))) sb.append(key).append("=REDACTED");
      else sb.append(pair);
    }
    return sb.toString();
  }

  /** Leading 3-digit status code of a cfhttp statusCode ("200 OK", "404 Not Found"), else 0. */
  static int statusCode(Object v) {
    if (v == null) return 0;
    if (v instanceof Number) return ((Number) v).intValue();
    Matcher m = STATUS.matcher(String.valueOf(v));
    return m.find() ? Integer.parseInt(m.group(1)) : 0;
  }
}
