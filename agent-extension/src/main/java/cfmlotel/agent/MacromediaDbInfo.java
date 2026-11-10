package cfmlotel.agent;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.sql.Connection;
import java.util.Locale;
import java.util.Map;
import java.util.Properties;
import java.util.WeakHashMap;
import java.util.logging.Level;
import java.util.logging.Logger;

/**
 * Helper injected next to the macromedia drivers. It reaches the agent's JDBC internals by reflection, through
 * the copies the agent injects into the connection's class loader: {@code JdbcConnectionUrlParser.parse()}
 * and the {@code JdbcData.CONNECTION_INFO} virtual field that the agent's statement advice reads. If a future
 * agent renames them, nothing breaks: queries stay traced, without the database's identity (logged once).
 */
public final class MacromediaDbInfo {

  private static final Logger logger = Logger.getLogger(MacromediaDbInfo.class.getName());

  /** Where the agent puts its JDBC library: relocated in the javaagent, plain in a library build. */
  private static final String[] PACKAGES = {
    "io.opentelemetry.javaagent.shaded.instrumentation.jdbc.internal.",
    "io.opentelemetry.instrumentation.jdbc.internal."
  };

  private static final Map<ClassLoader, Accessors> cache = new WeakHashMap<>();
  private static volatile boolean warned;

  private MacromediaDbInfo() {}

  /**
   * {@code jdbc:macromedia:sqlserver://h:1433;databaseName=x} (what ColdFusion connects with) and
   * {@code jdbc:macromedia_direct:sqlserver://...} (what the driver's metadata reports) as the
   * {@code jdbc:datadirect:} URL the agent can parse; null for any other URL.
   */
  public static String toDataDirectUrl(String url) {
    if (url == null) {
      return null;
    }
    String lower = url.toLowerCase(Locale.ROOT);
    for (String prefix : new String[] {"jdbc:macromedia_direct:", "jdbc:macromedia:"}) {
      if (lower.startsWith(prefix)) {
        return "jdbc:datadirect:" + url.substring(prefix.length());
      }
    }
    return null;
  }

  /** Records the database identity for a connection a macromedia driver just opened. */
  public static void update(String url, Properties props, Connection connection) {
    String dataDirectUrl = toDataDirectUrl(url);
    if (connection == null || dataDirectUrl == null) {
      return;
    }
    // The agent's statement advice reads the copy in the connection's class loader; the outer
    // MacromediaDriver lives in another one, with its own copy. Set both.
    ClassLoader connectionLoader = connection.getClass().getClassLoader();
    ClassLoader driverLoader = MacromediaDbInfo.class.getClassLoader();
    boolean done = set(connectionLoader, dataDirectUrl, props, connection);
    if (driverLoader != connectionLoader) {
      done |= set(driverLoader, dataDirectUrl, props, connection);
    }
    if (!done && !warned) {
      warned = true;
      logger.log(
          Level.WARNING,
          "cfml-otel agent extension: the javaagent's JDBC internals weren't found (a newer agent?), so "
              + "queries through ColdFusion's built-in drivers keep db.system=other_sql");
    }
  }

  private static boolean set(ClassLoader loader, String url, Properties props, Connection connection) {
    Accessors a = accessors(loader);
    if (a == null) {
      return false;
    }
    try {
      Object dbInfo = a.parse.invoke(null, url, props);
      if (a.intern != null) {
        dbInfo = a.intern.invoke(null, dbInfo);
      }
      a.virtualFieldSet.invoke(a.connectionInfo.get(null), connection, dbInfo);
      return true;
    } catch (Throwable t) {
      logger.log(Level.FINE, "cfml-otel agent extension: could not record the connection's database", t);
      return false;
    }
  }

  private static Accessors accessors(ClassLoader loader) {
    synchronized (cache) {
      if (cache.containsKey(loader)) {
        return cache.get(loader);
      }
      Accessors a = null;
      for (String pkg : PACKAGES) {
        a = Accessors.find(loader, pkg);
        if (a != null) {
          break;
        }
      }
      cache.put(loader, a);
      return a;
    }
  }

  private static final class Accessors {
    final Method parse;
    final Method intern;
    final Field connectionInfo;
    final Method virtualFieldSet;

    private Accessors(Method parse, Method intern, Field connectionInfo, Method virtualFieldSet) {
      this.parse = parse;
      this.intern = intern;
      this.connectionInfo = connectionInfo;
      this.virtualFieldSet = virtualFieldSet;
    }

    static Accessors find(ClassLoader loader, String pkg) {
      try {
        Class<?> parser = Class.forName(pkg + "JdbcConnectionUrlParser", false, loader);
        Class<?> data = Class.forName(pkg + "JdbcData", false, loader);
        Method parse = parser.getMethod("parse", String.class, Properties.class);
        Field connectionInfo = data.getField("CONNECTION_INFO");
        // the public VirtualField type, not the generated (non-public) implementation class
        Method set = connectionInfo.getType().getMethod("set", Object.class, Object.class);
        Method intern = null;
        for (Method m : data.getMethods()) {
          if (m.getName().equals("intern") && m.getParameterTypes().length == 1) {
            intern = m;
          }
        }
        return new Accessors(parse, intern, connectionInfo, set);
      } catch (Throwable t) {
        return null;
      }
    }
  }
}
