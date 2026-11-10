package cfmlotel.agent;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import io.opentelemetry.instrumentation.jdbc.internal.JdbcConnectionUrlParser;
import io.opentelemetry.instrumentation.jdbc.internal.JdbcData;
import io.opentelemetry.instrumentation.jdbc.internal.dbinfo.DbInfo;
import java.lang.reflect.Proxy;
import java.sql.Connection;
import java.util.Properties;
import org.junit.jupiter.api.Test;

class MacromediaDbInfoTest {

  // what ColdFusion's "Microsoft SQL Server" datasource connects with (neo-drivers.xml)
  static final String CF_URL =
      "jdbc:macromedia:sqlserver://db.example:1433;databaseName=orders;SelectMethod=direct;"
          + "sendStringParametersAsUnicode=false;querytimeout=0;applicationintent=ReadWrite";

  @Test
  void rewritesMacromediaUrls() {
    assertEquals(
        "jdbc:datadirect:sqlserver://h:1433;databaseName=x",
        MacromediaDbInfo.toDataDirectUrl("jdbc:macromedia:sqlserver://h:1433;databaseName=x"));
    // the driver's metadata reports this form
    assertEquals(
        "jdbc:datadirect:sqlserver://h:1433;DATABASENAME=x",
        MacromediaDbInfo.toDataDirectUrl("jdbc:macromedia_direct:sqlserver://h:1433;DATABASENAME=x"));
    assertEquals(
        "jdbc:datadirect:oracle://h:1521;ServiceName=x",
        MacromediaDbInfo.toDataDirectUrl("JDBC:Macromedia:oracle://h:1521;ServiceName=x"));
  }

  @Test
  void leavesOtherUrlsAlone() {
    assertNull(MacromediaDbInfo.toDataDirectUrl("jdbc:sqlserver://h:1433;databaseName=x"));
    assertNull(MacromediaDbInfo.toDataDirectUrl("jdbc:mysql://h/x"));
    assertNull(MacromediaDbInfo.toDataDirectUrl(null));
  }

  @Test
  void unpatchedParserCannotIdentifyColdFusionUrls() {
    // why this extension exists
    DbInfo info = JdbcConnectionUrlParser.parse(CF_URL, null);
    assertEquals("other_sql", info.getDbSystemName());
    assertNull(info.getDbNamespace());
  }

  @Test
  void rewrittenUrlIsIdentified() {
    DbInfo info = JdbcConnectionUrlParser.parse(MacromediaDbInfo.toDataDirectUrl(CF_URL), null);
    assertEquals("microsoft.sql_server", info.getDbSystemName());
    assertEquals("orders", info.getDbNamespace());
    String target = String.valueOf(info.getConfiguredServerTarget());
    assertTrue(target.contains("db.example") && target.contains("1433"), target);
  }

  @Test
  void otherDatabasesThroughColdFusionDrivers() {
    assertEquals(
        "oracle.db",
        JdbcConnectionUrlParser.parse(
                MacromediaDbInfo.toDataDirectUrl("jdbc:macromedia:oracle://h:1521;SID=orcl"), null)
            .getDbSystemName());
    assertEquals(
        "mysql",
        JdbcConnectionUrlParser.parse(
                MacromediaDbInfo.toDataDirectUrl("jdbc:macromedia:mysql://h:3306;DatabaseName=x"), null)
            .getDbSystemName());
  }

  @Test
  void updateRecordsTheDatabaseForTheConnection() {
    Connection connection =
        (Connection)
            Proxy.newProxyInstance(
                getClass().getClassLoader(), new Class<?>[] {Connection.class}, (p, m, a) -> null);
    JdbcData.CONNECTION_INFO.set(connection, JdbcConnectionUrlParser.parse(CF_URL, null));

    MacromediaDbInfo.update(CF_URL, new Properties(), connection);

    DbInfo info = JdbcData.CONNECTION_INFO.get(connection);
    assertEquals("microsoft.sql_server", info.getDbSystemName());
    assertEquals("orders", info.getDbNamespace());
  }

  @Test
  void updateIgnoresOtherDrivers() {
    Connection connection =
        (Connection)
            Proxy.newProxyInstance(
                getClass().getClassLoader(), new Class<?>[] {Connection.class}, (p, m, a) -> null);
    MacromediaDbInfo.update("jdbc:sqlserver://h:1433;databaseName=x", null, connection);
    assertNull(JdbcData.CONNECTION_INFO.get(connection));
  }
}
