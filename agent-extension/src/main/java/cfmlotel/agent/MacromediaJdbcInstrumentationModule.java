package cfmlotel.agent;

import static io.opentelemetry.javaagent.extension.matcher.AgentElementMatchers.implementsInterface;
import static java.util.Collections.singletonList;
import static net.bytebuddy.matcher.ElementMatchers.isPublic;
import static net.bytebuddy.matcher.ElementMatchers.named;
import static net.bytebuddy.matcher.ElementMatchers.nameStartsWith;
import static net.bytebuddy.matcher.ElementMatchers.returns;
import static net.bytebuddy.matcher.ElementMatchers.takesArgument;
import static net.bytebuddy.matcher.ElementMatchers.takesArguments;

import io.opentelemetry.javaagent.extension.instrumentation.InstrumentationModule;
import io.opentelemetry.javaagent.extension.instrumentation.TypeInstrumentation;
import io.opentelemetry.javaagent.extension.instrumentation.TypeTransformer;
import java.sql.Connection;
import java.util.Arrays;
import java.util.List;
import java.util.Properties;
import net.bytebuddy.asm.Advice;
import net.bytebuddy.description.type.TypeDescription;
import net.bytebuddy.matcher.ElementMatcher;

/**
 * Adobe ColdFusion's built-in JDBC drivers (Microsoft SQL Server, Oracle, DB2, MySQL, Sybase) are DataDirect
 * drivers renamed to {@code jdbc:macromedia:<db>://} URLs. The agent's JDBC URL parser doesn't know that
 * prefix, so their spans get {@code db.system=other_sql} and no host, port or database name. This module
 * runs after the agent's own {@code Driver.connect()} advice and replaces what it recorded for the new
 * connection with the result of parsing the URL as the {@code jdbc:datadirect:} URL it really is.
 *
 * <p>Same names as the agent's JDBC instrumentation's: {@code otel.instrumentation.jdbc.enabled=false}
 * turns this off too, and {@code otel.instrumentation.cfml-otel-macromedia-jdbc.enabled=false} alone.
 */
public final class MacromediaJdbcInstrumentationModule extends InstrumentationModule {

  public MacromediaJdbcInstrumentationModule() {
    super("cfml-otel-macromedia-jdbc", "jdbc");
  }

  /**
   * Before the agent's JDBC module (order 0): advice added first ends up outermost, so this exit advice runs
   * after the agent's own and has the last word.
   */
  @Override
  public int order() {
    return -1;
  }

  @Override
  public boolean isHelperClass(String className) {
    return className.startsWith("cfmlotel.agent.");
  }

  /** Built without the agent's muzzle plugin, so the helpers (nested classes too) are listed by hand. */
  @Override
  public List<String> getAdditionalHelperClassNames() {
    return Arrays.asList("cfmlotel.agent.MacromediaDbInfo", "cfmlotel.agent.MacromediaDbInfo$Accessors",
        "cfmlotel.agent.MacromediaDbInfo$Lookup");
  }

  @Override
  public List<TypeInstrumentation> typeInstrumentations() {
    return singletonList(new DriverInstrumentation());
  }

  static final class DriverInstrumentation implements TypeInstrumentation {
    @Override
    public ElementMatcher<TypeDescription> typeMatcher() {
      // macromedia.jdbc.MacromediaDriver and the per-database drivers it delegates to
      // (macromedia.jdbc.sqlserver.SQLServerDriver, ...)
      return nameStartsWith("macromedia.jdbc").and(implementsInterface(named("java.sql.Driver")));
    }

    @Override
    public void transform(TypeTransformer transformer) {
      transformer.applyAdviceToMethod(
          isPublic()
              .and(named("connect"))
              .and(takesArguments(2))
              .and(takesArgument(0, String.class))
              .and(returns(named("java.sql.Connection"))),
          MacromediaJdbcInstrumentationModule.class.getName() + "$ConnectAdvice");
    }
  }

  @SuppressWarnings("unused")
  public static final class ConnectAdvice {
    @Advice.OnMethodExit(onThrowable = Throwable.class, suppress = Throwable.class)
    public static void onExit(
        @Advice.Argument(0) String url,
        @Advice.Argument(1) Properties props,
        @Advice.Return Connection connection) {
      MacromediaDbInfo.update(url, props, connection);
    }
  }
}
