package cfmlotel.bridge;

import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.OpenTelemetry;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.api.common.AttributesBuilder;
import io.opentelemetry.api.logs.LogRecordBuilder;
import io.opentelemetry.api.logs.Logger;
import io.opentelemetry.api.logs.Severity;
import io.opentelemetry.api.metrics.DoubleCounter;
import io.opentelemetry.api.metrics.DoubleGauge;
import io.opentelemetry.api.metrics.DoubleHistogram;
import io.opentelemetry.api.metrics.DoubleUpDownCounter;
import io.opentelemetry.api.metrics.LongCounter;
import io.opentelemetry.api.metrics.LongGauge;
import io.opentelemetry.api.metrics.LongHistogram;
import io.opentelemetry.api.metrics.LongUpDownCounter;
import io.opentelemetry.api.metrics.Meter;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.SpanBuilder;
import io.opentelemetry.api.trace.SpanContext;
import io.opentelemetry.api.trace.SpanKind;
import io.opentelemetry.api.trace.StatusCode;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.context.Context;
import io.opentelemetry.context.Scope;
import io.opentelemetry.context.propagation.TextMapGetter;
import io.opentelemetry.context.propagation.TextMapSetter;

import java.io.PrintWriter;
import java.io.StringWriter;
import java.lang.reflect.Method;
import java.math.BigDecimal;
import java.math.BigInteger;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Date;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Static entry points for CFML.
 *
 * <p>Why this exists: when the OTel javaagent is attached, the objects the API hands back are the
 * agent's bridge classes, some of them hidden lambda classes. CFML engines invoke methods by
 * reflecting on the <em>concrete</em> class, which fails on Lucee (NoClassDefFoundError on 6.2,
 * IllegalAccessException on 7.0). Code compiled here calls through the public API interfaces,
 * which always works.
 *
 * <p>Rules for CFML callers: treat every returned OTel object as an opaque handle and pass it
 * back into this class. Methods are deliberately not overloaded so engines never have to guess.
 * "No value" is signalled with an empty string rather than null.
 */
public final class OtelBridge {

  public static final String VERSION = "0.2.0";

  /** The javaagent release the integration tests run against (build.sh AGENT_VERSION). */
  public static final String TESTED_AGENT_VERSION = "2.33.1";

  private static final AtomicLong SCOPE_SEQ = new AtomicLong();

  private OtelBridge() {}

  // ------------------------------------------------------------------------------------------
  // Environment
  // ------------------------------------------------------------------------------------------

  public static String version() {
    return VERSION;
  }

  /**
   * Startup self-check for CFML: versions, attached agents, and warnings (each {level, code, message})
   * explaining why nothing would be recorded or what is misconfigured. engine: "lucee" or "acf"; otel: the
   * instance's handle; sdkFallback: whether that handle is an SDK cfml-otel started.
   */
  public static Map<String, Object> diagnostics(String engine, Object otel, boolean sdkFallback) {
    return Diagnostics.report(Diagnostics.gather(engine, otel(otel), sdkFallback));
  }

  // ------------------------------------------------------------------------------------------
  // Outbound HTTP (stable HTTP semantic conventions)
  // ------------------------------------------------------------------------------------------

  /**
   * True when the javaagent is recording and its Apache HttpClient instrumentation is on, i.e. it creates
   * CLIENT spans for cfhttp by itself (correctly on ACF; on Lucee they start orphan traces, LDEV-6519).
   */
  public static boolean agentTracesHttpClient() {
    return isAgentBridged() && isActive() && Diagnostics.httpClientInstrumentationOn(Diagnostics::config);
  }

  /** http.request.method, server.address, server.port and url.full (credentials and signatures redacted). */
  public static Map<String, Object> httpClientAttributes(String method, String url) {
    return HttpClientSemconv.attributes(method, url);
  }

  /** A request's query string for url.query, with the same sensitive parameter values redacted as url.full. */
  public static String redactQuery(String query) {
    return HttpClientSemconv.redactQuery(query);
  }

  public static String httpSpanName(String method, String urlTemplate) {
    return HttpClientSemconv.spanName(method, urlTemplate);
  }

  /** Leading status code of a cfhttp statusCode such as "404 Not Found"; 0 when there is none. */
  public static int httpStatusCode(Object statusCode) {
    return HttpClientSemconv.statusCode(statusCode);
  }

  /** Strictly increasing, process-wide: orders scopes so they can be closed innermost-first. */
  public static long nextScopeSeq() {
    return SCOPE_SEQ.incrementAndGet();
  }

  // ------------------------------------------------------------------------------------------
  // Implementations. Each OTel CFC instance holds one OpenTelemetry handle: GlobalOpenTelemetry (the agent's,
  // or a no-op) or, with sdkFallback, an SDK of its own. Everything that needs one takes it as the first
  // argument, so applications that share these classes (one class loader) never share an SDK.
  // ------------------------------------------------------------------------------------------

  static OpenTelemetry global() {
    return GlobalOpenTelemetry.get();
  }

  private static OpenTelemetry otel(Object handle) {
    return handle instanceof OpenTelemetry ? (OpenTelemetry) handle : global();
  }

  /** GlobalOpenTelemetry: the agent's bridged instance, a registered SDK, or a no-op. */
  public static Object openTelemetry() {
    return global();
  }

  /** Class name of GlobalOpenTelemetry's implementation (diagnostics). */
  public static String implementationClass() {
    return global().getClass().getName();
  }

  /** Class name of the given handle's implementation. */
  public static String implementationOf(Object otel) {
    return otel(otel).getClass().getName();
  }

  /** True when GlobalOpenTelemetry is the javaagent's bridge into its SDK. */
  public static boolean isAgentBridged() {
    return global().getClass().getName().startsWith("io.opentelemetry.javaagent.");
  }

  /** True when the OTel javaagent is attached to this JVM (bridged or not). */
  public static boolean isAgentAttached() {
    return Diagnostics.gather("", global(), false).otelAgentPresent;
  }

  /** True when spans created through GlobalOpenTelemetry would be recorded/propagated. */
  public static boolean isActive() {
    return isActiveFor(global());
  }

  /** True when spans created through the given handle would actually be recorded/propagated. */
  public static boolean isActiveFor(Object otel) {
    Span probe = otel(otel).getTracer("cfml-otel.probe").spanBuilder("probe").startSpan();
    // Never end the probe span: an un-ended span is not exported.
    return probe.getSpanContext().isValid();
  }

  /**
   * Start an SDK of cfml-otel's own (opt-in sdkFallback), for one OTel instance. Configured from the standard
   * OTEL_* environment variables / otel.* system properties; {@code defaults} only fills in what those leave
   * unset; {@code overrides} (explicit CFC options) win over them. Needs the jars in lib/sdk/. Returns {started, serviceName, error, sdk (the handle, when started)}.
   */
  public static Map<String, Object> startSdkFallback(Map<?, ?> defaults, Map<?, ?> overrides) {
    try {
      return SdkFallback.start(defaults, overrides);
    } catch (LinkageError e) {
      Map<String, Object> r = new HashMap<>();
      r.put("started", false);
      r.put("serviceName", "");
      r.put("error", "the SDK jars are not on the classpath (add cfml-otel/lib/sdk/ to this.javaSettings.loadPaths): " + e);
      return r;
    }
  }

  /** Flush and shut down an SDK from startSdkFallback() (anything else is ignored). */
  public static void shutdownSdkFallback(Object sdk) {
    if (sdk instanceof OpenTelemetry && !(sdk == global())) SdkFallback.shutdown(sdk);
  }

  /** How many fallback SDKs are running in this class loader (tests and diagnostics). */
  public static int sdkFallbackCount() {
    try {
      return SdkFallback.liveCount();
    } catch (LinkageError e) {
      return 0;
    }
  }

  /**
   * HTTP status of a servlet response, unwrapping engine wrappers that don't track it (ACF's
   * getPageContext().getResponse() reports 0; the real one is a few getResponse() calls down). 0 if unknown.
   */
  public static int responseStatus(Object response) {
    Object r = response;
    for (int depth = 0; r != null && depth < 8; depth++) {
      try {
        Object s = r.getClass().getMethod("getStatus").invoke(r);
        if (s instanceof Integer && (Integer) s > 0) return (Integer) s;
      } catch (ReflectiveOperationException | RuntimeException ignored) {
        // not a status-tracking response
      }
      try {
        r = r.getClass().getMethod("getResponse").invoke(r);
      } catch (ReflectiveOperationException | RuntimeException e) {
        return 0;
      }
    }
    return 0;
  }

  // ------------------------------------------------------------------------------------------
  // Tracing
  // ------------------------------------------------------------------------------------------

  public static Object tracer(Object otel, String name, String version) {
    OpenTelemetry o = otel(otel);
    return isBlank(version) ? o.getTracer(name) : o.getTracer(name, version);
  }

  /**
   * Start a span. {@code parent} may be a Context handle (explicit parent), the string "root"
   * (no parent), or anything else / empty string (parent = current context).
   */
  public static Object startSpan(Object tracer, String name, String kind, Map<?, ?> attributes, Object parent) {
    SpanBuilder b = ((Tracer) tracer).spanBuilder(name).setSpanKind(parseKind(kind));
    if (parent instanceof Context) {
      b.setParent((Context) parent);
    } else if ("root".equals(parent)) {
      b.setNoParent();
    }
    if (attributes != null && !attributes.isEmpty()) {
      b.setAllAttributes(toAttributes(attributes));
    }
    return b.startSpan();
  }

  public static void setAttribute(Object span, String key, Object value) {
    Map<String, Object> m = new HashMap<>(1);
    m.put(key, value);
    ((Span) span).setAllAttributes(toAttributes(m));
  }

  public static void setAttributes(Object span, Map<?, ?> attributes) {
    if (attributes != null && !attributes.isEmpty()) {
      ((Span) span).setAllAttributes(toAttributes(attributes));
    }
  }

  public static void addEvent(Object span, String name, Map<?, ?> attributes) {
    ((Span) span).addEvent(name, toAttributes(attributes));
  }

  /**
   * Record an exception. Accepts a Java Throwable, a Lucee CatchBlock (unwrapped via
   * getPageException()), or any CFML exception struct (type/message/detail/stackTrace keys).
   */
  public static void recordException(Object span, Object error, Map<?, ?> attributes) {
    Span s = (Span) span;
    Attributes extra = toAttributes(attributes);
    Throwable t = toThrowable(error);
    if (t != null) {
      // The Throwable is usually an engine wrapper (lucee.runtime.exp.CustomTypeException,
      // coldfusion.runtime.CustomException, ...). Report the CFML type instead of that class name;
      // an exception.type the caller passed explicitly still wins.
      String type = cfmlType(error, t);
      if (!type.isEmpty()) {
        extra = Attributes.builder().put("exception.type", type).putAll(extra).build();
      }
      s.recordException(t, extra);
      return;
    }
    AttributesBuilder ab = Attributes.builder().putAll(extra);
    if (error instanceof Map) {
      Map<?, ?> m = (Map<?, ?>) error;
      String type = str(getIgnoreCase(m, "type"));
      String message = str(getIgnoreCase(m, "message"));
      String detail = str(getIgnoreCase(m, "detail"));
      String stack = str(getIgnoreCase(m, "stackTrace"));
      if (!type.isEmpty()) ab.put("exception.type", type);
      ab.put("exception.message", detail.isEmpty() ? message : message + " | " + detail);
      if (!stack.isEmpty()) ab.put("exception.stacktrace", stack);
    } else {
      ab.put("exception.message", str(error));
    }
    s.addEvent("exception", ab.build());
  }

  /** code: "OK", "ERROR" or "UNSET" (case-insensitive). */
  public static void setStatus(Object span, String code, String description) {
    StatusCode sc;
    switch (code == null ? "" : code.toUpperCase(Locale.ROOT)) {
      case "OK": sc = StatusCode.OK; break;
      case "ERROR": sc = StatusCode.ERROR; break;
      default: sc = StatusCode.UNSET;
    }
    if (isBlank(description)) {
      ((Span) span).setStatus(sc);
    } else {
      ((Span) span).setStatus(sc, description);
    }
  }

  public static void updateName(Object span, String name) {
    ((Span) span).updateName(name);
  }

  public static void endSpan(Object span) {
    ((Span) span).end();
  }

  public static boolean isRecording(Object span) {
    return ((Span) span).isRecording();
  }

  public static String spanTraceId(Object span) {
    SpanContext sc = ((Span) span).getSpanContext();
    return sc.isValid() ? sc.getTraceId() : "";
  }

  public static String spanSpanId(Object span) {
    SpanContext sc = ((Span) span).getSpanContext();
    return sc.isValid() ? sc.getSpanId() : "";
  }

  // ------------------------------------------------------------------------------------------
  // Context
  // ------------------------------------------------------------------------------------------

  public static Object currentContext() {
    return Context.current();
  }

  public static Object currentSpan() {
    return Span.current();
  }

  public static String currentTraceId() {
    return spanTraceId(Span.current());
  }

  public static String currentSpanId() {
    return spanSpanId(Span.current());
  }

  public static Object spanFromContext(Object context) {
    return Span.fromContext((Context) context);
  }

  public static Object contextWithSpan(Object context, Object span) {
    return ((Context) context).with((Span) span);
  }

  /** Make a span current on this thread. The returned Scope MUST be closed on the same thread. */
  public static Object makeSpanCurrent(Object span) {
    return ((Span) span).makeCurrent();
  }

  /** Make a context current on this thread. The returned Scope MUST be closed on the same thread. */
  public static Object makeContextCurrent(Object context) {
    return ((Context) context).makeCurrent();
  }

  public static void closeScope(Object scope) {
    ((Scope) scope).close();
  }

  // ------------------------------------------------------------------------------------------
  // Propagation (W3C traceparent/tracestate + baggage, per the configured propagators)
  // ------------------------------------------------------------------------------------------

  private static final TextMapSetter<Map<String, String>> MAP_SETTER = (carrier, key, value) -> {
    if (carrier != null) carrier.put(key, value);
  };

  private static final TextMapGetter<Map<?, ?>> MAP_GETTER = new TextMapGetter<Map<?, ?>>() {
    @Override
    public Iterable<String> keys(Map<?, ?> carrier) {
      List<String> keys = new ArrayList<>();
      for (Object k : carrier.keySet()) keys.add(String.valueOf(k));
      return keys;
    }

    @Override
    public String get(Map<?, ?> carrier, String key) {
      if (carrier == null) return null;
      Object v = getIgnoreCase(carrier, key);
      return v == null ? null : String.valueOf(v);
    }
  };

  /** Headers to send downstream for the given context (or current context if not a Context). */
  public static Map<String, String> injectHeaders(Object otel, Object context) {
    Context ctx = context instanceof Context ? (Context) context : Context.current();
    Map<String, String> headers = new HashMap<>();
    otel(otel).getPropagators().getTextMapPropagator().inject(ctx, headers, MAP_SETTER);
    return headers;
  }

  /** Extract a remote parent context from inbound headers (case-insensitive keys). */
  public static Object extractContext(Object otel, Map<?, ?> headers) {
    return otel(otel).getPropagators().getTextMapPropagator()
        .extract(Context.current(), headers, MAP_GETTER);
  }

  /**
   * Like extractContext(), but onto the root context rather than this thread's current one. For a request's
   * SERVER span: whatever an earlier request left current on a pooled thread must never become its parent.
   * Without inbound trace headers this is the root context, i.e. a new trace.
   */
  public static Object extractRootContext(Object otel, Map<?, ?> headers) {
    return otel(otel).getPropagators().getTextMapPropagator()
        .extract(Context.root(), headers, MAP_GETTER);
  }

  // ------------------------------------------------------------------------------------------
  // Metrics
  // ------------------------------------------------------------------------------------------

  public static Object meter(Object otel, String name, String version) {
    OpenTelemetry o = otel(otel);
    return isBlank(version)
        ? o.getMeter(name)
        : o.meterBuilder(name).setInstrumentationVersion(version).build();
  }

  /**
   * Create an instrument. type: counter | upDownCounter | histogram | gauge.
   * valueType: long | double.
   */
  public static Object instrument(Object meter, String type, String valueType, String name, String description, String unit) {
    Meter m = (Meter) meter;
    boolean isLong = "long".equalsIgnoreCase(valueType);
    String d = description == null ? "" : description;
    String u = unit == null ? "" : unit;
    switch (type == null ? "" : type.toLowerCase(Locale.ROOT)) {
      case "counter":
        return isLong
            ? m.counterBuilder(name).setDescription(d).setUnit(u).build()
            : m.counterBuilder(name).ofDoubles().setDescription(d).setUnit(u).build();
      case "updowncounter":
        return isLong
            ? m.upDownCounterBuilder(name).setDescription(d).setUnit(u).build()
            : m.upDownCounterBuilder(name).ofDoubles().setDescription(d).setUnit(u).build();
      case "histogram":
        return isLong
            ? m.histogramBuilder(name).ofLongs().setDescription(d).setUnit(u).build()
            : m.histogramBuilder(name).setDescription(d).setUnit(u).build();
      case "gauge":
        return isLong
            ? m.gaugeBuilder(name).ofLongs().setDescription(d).setUnit(u).build()
            : m.gaugeBuilder(name).setDescription(d).setUnit(u).build();
      default:
        throw new IllegalArgumentException("Unknown instrument type: " + type);
    }
  }

  /** Add to a counter / up-down counter, record a histogram value or set a gauge. */
  public static void record(Object instrument, Object value, Map<?, ?> attributes) {
    Attributes a = toAttributes(attributes);
    Number n = toNumber(value);
    if (instrument instanceof LongCounter) ((LongCounter) instrument).add(toLong(n), a);
    else if (instrument instanceof DoubleCounter) ((DoubleCounter) instrument).add(n.doubleValue(), a);
    else if (instrument instanceof LongUpDownCounter) ((LongUpDownCounter) instrument).add(toLong(n), a);
    else if (instrument instanceof DoubleUpDownCounter) ((DoubleUpDownCounter) instrument).add(n.doubleValue(), a);
    else if (instrument instanceof LongHistogram) ((LongHistogram) instrument).record(toLong(n), a);
    else if (instrument instanceof DoubleHistogram) ((DoubleHistogram) instrument).record(n.doubleValue(), a);
    else if (instrument instanceof LongGauge) ((LongGauge) instrument).set(toLong(n), a);
    else if (instrument instanceof DoubleGauge) ((DoubleGauge) instrument).set(n.doubleValue(), a);
    else throw new IllegalArgumentException("Not an OTel instrument: " + (instrument == null ? "null" : instrument.getClass().getName()));
  }

  // ------------------------------------------------------------------------------------------
  // Logs
  // ------------------------------------------------------------------------------------------

  public static Object logger(Object otel, String name) {
    return otel(otel).getLogsBridge().get(name);
  }

  /** Emit a log record correlated with the current span. severity: TRACE|DEBUG|INFO|WARN|ERROR|FATAL. */
  public static void emitLog(Object logger, String severity, String body, Map<?, ?> attributes) {
    Severity sev = parseSeverity(severity);
    LogRecordBuilder b = ((Logger) logger).logRecordBuilder()
        .setSeverity(sev)
        .setSeverityText(sev == Severity.UNDEFINED_SEVERITY_NUMBER ? str(severity) : sev.name().replaceAll("[0-9]", ""))
        .setBody(body == null ? "" : body)
        .setContext(Context.current());
    if (attributes != null && !attributes.isEmpty()) b.setAllAttributes(toAttributes(attributes));
    b.emit();
  }

  // ------------------------------------------------------------------------------------------
  // Conversions
  // ------------------------------------------------------------------------------------------

  /**
   * CFML struct -> Attributes. Strings stay strings (CFML "200" is NOT coerced); integral
   * doubles become longs (Lucee represents every number as a double); lists/arrays become
   * homogeneous array attributes, falling back to string arrays when mixed.
   */
  static Attributes toAttributes(Map<?, ?> map) {
    if (map == null || map.isEmpty()) return Attributes.empty();
    AttributesBuilder b = Attributes.builder();
    for (Map.Entry<?, ?> e : map.entrySet()) {
      if (e.getKey() == null || e.getValue() == null) continue;
      String k = String.valueOf(e.getKey());
      Object v = normalize(e.getValue());
      if (v instanceof String) b.put(k, (String) v);
      else if (v instanceof Boolean) b.put(k, (Boolean) v);
      else if (v instanceof Number) putNumber(b, k, (Number) v);
      else if (v instanceof Collection || v instanceof Object[]) putArray(b, k, v instanceof Collection ? ((Collection<?>) v).toArray() : (Object[]) v);
      else if (v instanceof Date) b.put(k, ((Date) v).toInstant().toString());
      else b.put(k, String.valueOf(v));
    }
    return b.build();
  }

  private static void putNumber(AttributesBuilder b, String k, Number n) {
    if (isIntegral(n)) b.put(k, n.longValue());
    else b.put(k, n.doubleValue());
  }

  /**
   * Engine-specific value types -> plain Java. Adobe CF represents CFML booleans as
   * coldfusion.runtime.CFBoolean (not java.lang.Boolean), which would otherwise become a string.
   */
  static Object normalize(Object v) {
    if (v == null || v instanceof String || v instanceof Boolean || v instanceof Number) return v;
    if (v.getClass().getName().endsWith(".CFBoolean")) {
      try {
        Object r = v.getClass().getMethod("booleanValue").invoke(v);
        if (r instanceof Boolean) return r;
      } catch (ReflectiveOperationException | RuntimeException ignored) {
        // fall through to string parsing
      }
      String s = String.valueOf(v).trim();
      return "true".equalsIgnoreCase(s) || "yes".equalsIgnoreCase(s);
    }
    return v;
  }

  private static void putArray(AttributesBuilder b, String k, Object[] raw) {
    Object[] arr = new Object[raw.length];
    for (int i = 0; i < raw.length; i++) arr[i] = normalize(raw[i]);
    boolean allStr = true, allBool = true, allNum = true, allIntegral = true;
    for (Object o : arr) {
      allStr &= o instanceof String;
      allBool &= o instanceof Boolean;
      allNum &= o instanceof Number;
      allIntegral &= o instanceof Number && isIntegral((Number) o);
    }
    if (arr.length > 0 && allBool) {
      boolean[] out = new boolean[arr.length];
      for (int i = 0; i < arr.length; i++) out[i] = (Boolean) arr[i];
      b.put(k, out);
    } else if (arr.length > 0 && allNum && allIntegral) {
      long[] out = new long[arr.length];
      for (int i = 0; i < arr.length; i++) out[i] = ((Number) arr[i]).longValue();
      b.put(k, out);
    } else if (arr.length > 0 && allNum) {
      double[] out = new double[arr.length];
      for (int i = 0; i < arr.length; i++) out[i] = ((Number) arr[i]).doubleValue();
      b.put(k, out);
    } else {
      String[] out = new String[arr.length];
      for (int i = 0; i < arr.length; i++) out[i] = String.valueOf(arr[i]);
      b.put(k, out);
    }
  }

  private static boolean isIntegral(Number n) {
    if (n instanceof Integer || n instanceof Long || n instanceof Short || n instanceof Byte || n instanceof BigInteger) return true;
    if (n instanceof BigDecimal) {
      BigDecimal bd = (BigDecimal) n;
      return bd.signum() == 0 || bd.scale() <= 0 || bd.stripTrailingZeros().scale() <= 0;
    }
    double d = n.doubleValue();
    return !Double.isInfinite(d) && d == Math.rint(d) && Math.abs(d) < 9.007199254740992E15;
  }

  private static Number toNumber(Object v) {
    if (v instanceof Number) return (Number) v;
    if (v instanceof Boolean) return ((Boolean) v) ? 1 : 0;
    return Double.valueOf(String.valueOf(v).trim());
  }

  private static Throwable toThrowable(Object o) {
    if (o instanceof Throwable) return (Throwable) o;
    if (o == null) return null;
    for (String getter : new String[] {"getPageException", "getThrowable", "getCause"}) {
      try {
        Method m = o.getClass().getMethod(getter);
        Object r = m.invoke(o);
        if (r instanceof Throwable) return (Throwable) r;
      } catch (ReflectiveOperationException | RuntimeException ignored) {
        // not that kind of object
      }
    }
    return null;
  }

  /**
   * The CFML exception type (cfcatch.type), or "" when the error has none: the "type" key of a
   * Lucee catch struct, else getTypeAsString() (Lucee PageException) / getType() (ACF NeoException).
   * The getters are only tried on the engines' own exception classes: a third-party Java exception
   * can have a getType() that means something else entirely.
   */
  private static String cfmlType(Object error, Throwable t) {
    if (error instanceof Map) {
      String type = str(getIgnoreCase((Map<?, ?>) error, "type")).trim();
      if (!type.isEmpty()) return type;
    }
    String cls = t.getClass().getName();
    if (!cls.startsWith("lucee.") && !cls.startsWith("coldfusion.")) return "";
    for (String getter : new String[] {"getTypeAsString", "getType"}) {
      try {
        Object r = t.getClass().getMethod(getter).invoke(t);
        if (r instanceof String && !((String) r).trim().isEmpty()) return ((String) r).trim();
      } catch (ReflectiveOperationException | RuntimeException ignored) {
        // plain Java exception: keep its class name
      }
    }
    return "";
  }

  /** Value for a long instrument: fractional values are rounded to nearest rather than truncated. */
  private static long toLong(Number n) {
    return isIntegral(n) ? n.longValue() : Math.round(n.doubleValue());
  }

  private static Object getIgnoreCase(Map<?, ?> m, String key) {
    Object v = m.get(key);
    if (v != null) return v;
    for (Map.Entry<?, ?> e : m.entrySet()) {
      if (e.getKey() != null && key.equalsIgnoreCase(String.valueOf(e.getKey()))) return e.getValue();
    }
    return null;
  }

  private static SpanKind parseKind(String kind) {
    if (isBlank(kind)) return SpanKind.INTERNAL;
    switch (kind.toUpperCase(Locale.ROOT)) {
      case "SERVER": return SpanKind.SERVER;
      case "CLIENT": return SpanKind.CLIENT;
      case "PRODUCER": return SpanKind.PRODUCER;
      case "CONSUMER": return SpanKind.CONSUMER;
      default: return SpanKind.INTERNAL;
    }
  }

  private static Severity parseSeverity(String s) {
    switch (s == null ? "" : s.toUpperCase(Locale.ROOT)) {
      case "TRACE": return Severity.TRACE;
      case "DEBUG": return Severity.DEBUG;
      case "INFO": case "INFORMATION": return Severity.INFO;
      case "WARN": case "WARNING": return Severity.WARN;
      case "ERROR": return Severity.ERROR;
      case "FATAL": return Severity.FATAL;
      default: return Severity.UNDEFINED_SEVERITY_NUMBER;
    }
  }

  private static boolean isBlank(String s) {
    return s == null || s.trim().isEmpty();
  }

  private static String str(Object o) {
    return o == null ? "" : String.valueOf(o);
  }

  /** Exposed for CFML diagnostics when a Throwable needs rendering. */
  public static String stackTrace(Object error) {
    Throwable t = toThrowable(error);
    if (t == null) return "";
    StringWriter sw = new StringWriter();
    t.printStackTrace(new PrintWriter(sw));
    return sw.toString();
  }
}
