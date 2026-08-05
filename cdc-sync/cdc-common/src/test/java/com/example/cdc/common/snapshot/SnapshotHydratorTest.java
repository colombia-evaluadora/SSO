package com.example.cdc.common.snapshot;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import javax.sql.DataSource;
import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Unit tests for {@link SnapshotHydrator}.
 *
 * <p>Mockito's inline mock-maker (default in Spring Boot 3.3.5) fails to
 * mock {@code javax.sql.DataSource}, {@code java.sql.Connection},
 * {@code PreparedStatement} and {@code ResultSet} on JDK 25 because those
 * interfaces live in sealed JDK modules that the mock-maker can no longer
 * instrument. We sidestep Mockito entirely by using
 * {@link java.lang.reflect.Proxy} over those JDBC interfaces plus a small
 * {@link StubDataSource} for the top-level dependency.
 *
 * <p>Each {@link StubPreparedStatement} is wired to a canned result set
 * keyed on a substring match against the SQL it received — exactly the
 * dispatch shape the production hydrator uses at boot.
 */
class SnapshotHydratorTest {

    private StubDataSource ds;

    @BeforeEach
    void setUp() {
        StubConnection conn = new StubConnection();
        conn.whenSqlContains("tlista_valor", stubResultSet(
                row("categoria", "JORNADA", "codigo", "JORNADA_COD", "pk_tlista_valor", 10L),
                row("categoria", "MODELO_PEDAGOGICO", "codigo", "MODELO_COD", "pk_tlista_valor", 20L)));
        conn.whenSqlContains("tmatricula_socioeconomico", stubResultSet(
                row("pk_tmatricula", 42L, "estrato", 3, "ingresos", 1500)));
        conn.whenSqlContains("tmatricula_promocion", stubResultSet(
                row("pk_tmatricula", 7L, "promocion_anticipada", "S", "motivo", "X")));
        conn.whenSqlContains("tsede_usuario", stubResultSet(
                row("pk_tsede_usuario", 1L, "fk_tsede", 10L, "fk_trol", 5L, "fk_tusuario", 99L,
                    "fk_tlv_jornada", "JORNADA_COD", "orden", 1)));
        conn.whenSqlContains("tcriterio_evaluacion", stubResultSet(
                row("pk_periodo_academico", 100L, "minima", 3.0, "maxima", 5.0)));
        conn.whenSqlContains("tgrupo", stubResultSet(
                row("pk_tgrupo", 1L, "fk_tlv_jornada", "JORNADA_COD", "fk_tlv_modelo_pedagogico", "MODELO_COD")));

        ds = new StubDataSource(() -> conn.asJdkConnection());
    }

    @Test
    void hydratesAllCachesOnSuccess() {
        SnapshotHydrator hydrator = new SnapshotHydrator(ds);
        SnapshotCache cache = hydrator.hydrate();

        assertThat(cache.matriculaSocio()).isNotEmpty();
        assertThat(cache.matriculaPromo()).isNotEmpty();
        assertThat(cache.sedeUsuario()).isNotEmpty();
        assertThat(cache.criterio()).isNotEmpty();
        assertThat(cache.grupo()).isNotEmpty();
        assertThat(cache.jornadaReverseMap()).isNotEmpty();
        assertThat(cache.modeloPedagogicoReverseMap()).isNotEmpty();

        assertThat(cache.matriculaSocio().get(42L)).containsEntry("estrato", 3);
        assertThat(cache.matriculaPromo().get(7L)).containsEntry("promocion_anticipada", "S");
        SnapshotCache.SedeUsuarioRow suRow = cache.sedeUsuario().get(1L);
        assertThat(suRow.fkSede()).isEqualTo(10L);
        assertThat(suRow.fkRol()).isEqualTo(5L);
        assertThat(suRow.fkUsuario()).isEqualTo(99L);
        assertThat(suRow.fkLvJornada()).isEqualTo("JORNADA_COD");
        assertThat(suRow.orden()).isEqualTo(1);
        assertThat(cache.criterio().get(100L)).containsEntry("minima", 3.0);
        assertThat(cache.grupo().get(1L)).containsEntry("fk_tlv_jornada", "JORNADA_COD");
        // Reverse maps key on the row's `codigo` value (not the `categoria`)
        // so Phase-2 transformers can lookup e.g.
        // jornadaReverseMap().get("JORNADA_COD") when rewriting fk_tlv_jornada.
        assertThat(cache.jornadaReverseMap()).containsEntry("JORNADA_COD", 10L);
        assertThat(cache.modeloPedagogicoReverseMap()).containsEntry("MODELO_COD", 20L);
    }

    @Test
    void hydrationFailureReturnsEmptyCache() {
        StubDataSource brokenDs = new StubDataSource(() -> {
            throw new SQLException("boom");
        });

        SnapshotHydrator hydrator = new SnapshotHydrator(brokenDs);
        SnapshotCache cache = hydrator.hydrate();

        assertThat(cache.matriculaSocio()).isEmpty();
        assertThat(cache.sedeUsuario()).isEmpty();
        assertThat(cache.jornadaReverseMap()).isEmpty();
    }

    @Test
    void partialFailureLeavesOtherCachesPopulated() {
        // Same fixture as the happy-path test, but the tlista_valor query is
        // configured to throw — every other query returns its normal data.
        StubConnection conn = new StubConnection();
        conn.whenSqlFails("tlista_valor");
        conn.whenSqlContains("tmatricula_socioeconomico", stubResultSet(
                row("pk_tmatricula", 42L, "estrato", 3, "ingresos", 1500)));
        conn.whenSqlContains("tmatricula_promocion", stubResultSet(
                row("pk_tmatricula", 7L, "promocion_anticipada", "S", "motivo", "X")));
        conn.whenSqlContains("tsede_usuario", stubResultSet(
                row("pk_tsede_usuario", 1L, "fk_tsede", 10L, "fk_trol", 5L, "fk_tusuario", 99L,
                    "fk_tlv_jornada", "JORNADA_COD", "orden", 1)));
        conn.whenSqlContains("tcriterio_evaluacion", stubResultSet(
                row("pk_periodo_academico", 100L, "minima", 3.0, "maxima", 5.0)));
        conn.whenSqlContains("tgrupo", stubResultSet(
                row("pk_tgrupo", 1L, "fk_tlv_jornada", "JORNADA_COD", "fk_tlv_modelo_pedagogico", "MODELO_COD")));

        SnapshotHydrator hydrator = new SnapshotHydrator(new StubDataSource(() -> conn.asJdkConnection()));
        SnapshotCache cache = hydrator.hydrate();

        // The failing query's contribution stays empty (tlista_valor drives
        // both reverse maps), but every other query that successfully ran is
        // present in the cache. transformers that need reverse maps will log
        // WARN + skip per spec 7.1 — non-fatal degraded mode.
        assertThat(cache.jornadaReverseMap()).isEmpty();
        assertThat(cache.modeloPedagogicoReverseMap()).isEmpty();
        assertThat(cache.matriculaSocio()).isNotEmpty();
        assertThat(cache.matriculaPromo()).isNotEmpty();
        assertThat(cache.sedeUsuario()).isNotEmpty();
        assertThat(cache.criterio()).isNotEmpty();
        assertThat(cache.grupo()).isNotEmpty();
    }

    /* ---------------- test doubles ---------------- */

    /** Minimal {@link DataSource} that only ever opens a fixed
     * {@link Connection}. Both accessor methods are delegated so the
     * try-with-resources inside {@link SnapshotHydrator} closes cleanly. */
    private static final class StubDataSource implements DataSource {

        private final StubConnectionSupplier supplier;

        StubDataSource(StubConnectionSupplier supplier) {
            this.supplier = supplier;
        }

        @Override public Connection getConnection() throws SQLException {
            return supplier.get();
        }
        @Override public Connection getConnection(String username, String password) throws SQLException {
            return supplier.get();
        }
        @Override public java.io.PrintWriter getLogWriter() { return null; }
        @Override public void setLogWriter(java.io.PrintWriter out) { /* no-op */ }
        @Override public void setLoginTimeout(int seconds) { /* no-op */ }
        @Override public int getLoginTimeout() { return 0; }
        @Override public java.util.logging.Logger getParentLogger() throws java.sql.SQLFeatureNotSupportedException {
            throw new java.sql.SQLFeatureNotSupportedException();
        }
        @Override public <T> T unwrap(Class<T> iface) { return null; }
        @Override public boolean isWrapperFor(Class<?> iface) { return false; }
    }

    @FunctionalInterface
    private interface StubConnectionSupplier {
        Connection get() throws SQLException;
    }

    /** Connection stub: caches prepared statements keyed on SQL substring. */
    private static final class StubConnection {

        private final Map<String, ResultSet> preparedByMarker = new HashMap<>();
        private final java.util.Set<String> failingMarkers = new java.util.HashSet<>();

        void whenSqlContains(String marker, ResultSet canned) {
            preparedByMarker.put(marker, canned);
        }

        /** Marks a SQL marker as one whose {@code executeQuery()} should raise
         * an {@link SQLException}, simulating a per-query failure. */
        void whenSqlFails(String marker) {
            failingMarkers.add(marker);
        }

        Connection asJdkConnection() {
            InvocationHandler h = (proxy, method, args) -> invokeConnection(method, args);
            return (Connection) Proxy.newProxyInstance(
                    StubConnection.class.getClassLoader(),
                    new Class<?>[] {Connection.class},
                    h);
        }

        private Object invokeConnection(Method method, Object[] args) throws SQLException {
            switch (method.getName()) {
                case "prepareStatement":
                    String sql = (String) args[0];
                    for (String marker : failingMarkers) {
                        if (sql.contains(marker)) {
                            return stubFailingPreparedStatement(marker);
                        }
                    }
                    ResultSet rs = null;
                    for (Map.Entry<String, ResultSet> e : preparedByMarker.entrySet()) {
                        if (sql.contains(e.getKey())) {
                            rs = e.getValue();
                            break;
                        }
                    }
                    if (rs == null) {
                        rs = emptyResultSet();
                    }
                    return stubPreparedStatement(rs);
                case "close":
                    return null;
                case "isClosed":
                    return Boolean.FALSE;
                default:
                    // ResultSet-related calls would normally delegate to a statement.
                    return defaultFor(method.getReturnType());
            }
        }
    }

    /** Builds a {@link PreparedStatement} proxy whose {@code executeQuery()} returns the
     * supplied canned result set, with {@code setQueryTimeout} and {@code close}
     * accepting args but otherwise being a no-op. */
    private static PreparedStatement stubPreparedStatement(ResultSet canned) {
        InvocationHandler h = (proxy, method, args) -> {
            switch (method.getName()) {
                case "executeQuery":
                    return canned;
                case "setQueryTimeout":
                    return null;
                case "close":
                case "clearWarnings":
                    return null;
                case "isClosed":
                    return Boolean.FALSE;
                case "execute":
                    return Boolean.FALSE;
                default:
                    return defaultFor(method.getReturnType());
            }
        };
        return (PreparedStatement) Proxy.newProxyInstance(
                SnapshotHydratorTest.class.getClassLoader(),
                new Class<?>[] {PreparedStatement.class},
                h);
    }

    /** Builds a {@link PreparedStatement} proxy whose {@code executeQuery()}
     * raises {@link SQLException}, simulating a per-query PG failure.
     * The proxy is bound to the supplied marker so log lines can trace the
     * failure back to a particular canned query. */
    private static PreparedStatement stubFailingPreparedStatement(String marker) {
        InvocationHandler h = (proxy, method, args) -> {
            switch (method.getName()) {
                case "executeQuery":
                    throw new SQLException("simulated failure for marker=" + marker);
                case "setQueryTimeout":
                    return null;
                case "close":
                case "clearWarnings":
                    return null;
                case "isClosed":
                    return Boolean.FALSE;
                default:
                    return defaultFor(method.getReturnType());
            }
        };
        return (PreparedStatement) Proxy.newProxyInstance(
                SnapshotHydratorTest.class.getClassLoader(),
                new Class<?>[] {PreparedStatement.class},
                h);
    }

    /** In-memory {@link ResultSet} backed by a list of row-maps. Column lookup
     * happens by label (the {@link ResultSetMetaData} reports the same labels).
     * Each {@link ResultSet} carries its own cursor, so multiple result sets
     * returned over the lifetime of a single connection never trample one
     * another's row pointer. */
    private static ResultSet stubResultSet(Map<String, Object>... rows) {
        List<Map<String, Object>> all = new ArrayList<>();
        for (Map<String, Object> r : rows) all.add(new LinkedHashMap<>(r));
        List<String> labels = rows.length > 0
                ? new ArrayList<>(rows[0].keySet())
                : new ArrayList<>();
        ResultSetMetaData md = stubMetaData(labels);
        final int[] cursor = {-1};

        InvocationHandler h = (proxy, method, args) -> {
            switch (method.getName()) {
                case "getMetaData":
                    return md;
                case "next": {
                    int next = cursor[0] + 1;
                    if (next >= all.size()) {
                        cursor[0] = all.size();
                        return Boolean.FALSE;
                    }
                    cursor[0] = next;
                    return Boolean.TRUE;
                }
                case "getString": {
                    String label = (String) args[0];
                    return asString(currentRow(all, cursor, label));
                }
                case "getLong": {
                    String label = (String) args[0];
                    Object v = currentRow(all, cursor, label);
                    return v == null ? 0L : ((Number) v).longValue();
                }
                case "getInt": {
                    String label = (String) args[0];
                    Object v = currentRow(all, cursor, label);
                    return v == null ? 0 : ((Number) v).intValue();
                }
                case "getObject": {
                    if (args.length == 0) return null;
                    if (args[0] instanceof String) {
                        return currentRow(all, cursor, (String) args[0]);
                    }
                    int idx = (Integer) args[0];
                    String label = labels.get(idx - 1);
                    return currentRow(all, cursor, label);
                }
                case "wasNull":
                    return Boolean.FALSE;
                case "close":
                    return null;
                case "isClosed":
                    return Boolean.FALSE;
                default:
                    return defaultFor(method.getReturnType());
            }
        };
        return (ResultSet) Proxy.newProxyInstance(
                SnapshotHydratorTest.class.getClassLoader(),
                new Class<?>[] {ResultSet.class},
                h);
    }

    private static ResultSet emptyResultSet() {
        return stubResultSet(new Map[0]);
    }

    private static ResultSetMetaData stubMetaData(List<String> labels) {
        InvocationHandler h = (proxy, method, args) -> {
            switch (method.getName()) {
                case "getColumnCount":
                    return labels.size();
                case "getColumnLabel":
                case "getColumnName":
                    return labels.get((Integer) args[0] - 1);
                default:
                    return defaultFor(method.getReturnType());
            }
        };
        return (ResultSetMetaData) Proxy.newProxyInstance(
                SnapshotHydratorTest.class.getClassLoader(),
                new Class<?>[] {ResultSetMetaData.class},
                h);
    }

    /* ---------------- shared cursor + helpers ---------------- */

    private static Object currentRow(List<Map<String, Object>> all, int[] cursor, String label) {
        if (cursor[0] < 0 || cursor[0] >= all.size()) return null;
        return all.get(cursor[0]).get(label);
    }

    private static String asString(Object v) {
        return v == null ? null : v.toString();
    }

    /** Sensible return value for unstubbed {@link Method} invocations. */
    private static Object defaultFor(Class<?> returnType) {
        if (returnType == void.class) return null;
        if (returnType == boolean.class) return Boolean.FALSE;
        if (returnType == int.class) return 0;
        if (returnType == long.class) return 0L;
        if (returnType == short.class) return (short) 0;
        if (returnType == byte.class) return (byte) 0;
        if (returnType == double.class) return 0d;
        if (returnType == float.class) return 0f;
        if (returnType == char.class) return '\0';
        return null;
    }

    private static Map<String, Object> row(Object... labelValuePairs) {
        Map<String, Object> r = new LinkedHashMap<>();
        for (int i = 0; i + 1 < labelValuePairs.length; i += 2) {
            r.put((String) labelValuePairs[i], labelValuePairs[i + 1]);
        }
        return r;
    }
}
