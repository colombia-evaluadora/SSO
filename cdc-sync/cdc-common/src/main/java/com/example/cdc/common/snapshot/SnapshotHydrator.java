package com.example.cdc.common.snapshot;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Boot-time snapshot loader that hydrates an immutable {@link SnapshotCache}
 * by issuing six bulk read-only queries against the PG {@code academico}
 * schema. Wired as a Spring {@code @Component} so the {@code DataSource}
 * bean (configured in {@code cdc-worker}) is injected by the container
 * before {@link #hydrate()} is invoked from
 * {@code ApplicationReadyEvent}.
 *
 * <p>Failure handling mirrors spec section 3.7:
 * <ul>
 *   <li>If a single query fails, log ERROR per query and continue (degraded mode).</li>
 *   <li>If every query fails, {@link #hydrate()} returns
 *       {@link SnapshotCache#empty()} so dependent transformers can still
 *       be instantiated — they will WARN + skip on the first cache miss.</li>
 * </ul>
 *
 * <p>Each {@link PreparedStatement} uses a 60-second {@code Statement.queryTimeout}
 * to prevent a degraded PG replica from blocking worker startup indefinitely.
 */
@Component
public class SnapshotHydrator {

    private static final Logger log = LoggerFactory.getLogger(SnapshotHydrator.class);
    private static final int QUERY_TIMEOUT_SEC = 60;

    private final DataSource pgDataSource;

    public SnapshotHydrator(DataSource pgDataSource) {
        this.pgDataSource = pgDataSource;
    }

    /**
     * Runs the six bulk queries and returns the populated cache. Never
     * throws — SQL errors are caught and logged, the method degrades
     * gracefully to an empty cache.
     */
    public SnapshotCache hydrate() {
        Map<String, Long> jornadaReverseMap = new HashMap<>();
        Map<String, Long> modeloPedagogicoReverseMap = new HashMap<>();
        Map<Long, Map<String, Object>> socio = new HashMap<>();
        Map<Long, Map<String, Object>> promo = new HashMap<>();
        Map<Long, SnapshotCache.SedeUsuarioRow> sedeUsuario = new HashMap<>();
        Map<Long, Map<String, Object>> criterio = new HashMap<>();
        Map<Long, Map<String, Object>> grupo = new HashMap<>();
        Map<String, Map<String, Long>> tlistaValorIndex = new HashMap<>();

        try (Connection conn = pgDataSource.getConnection()) {
            try {
                runQuery(conn,
                    "SELECT categoria, codigo, pk_tlista_valor FROM tlista_valor "
                        + "WHERE categoria IN ('JORNADA','MODELO_PEDAGOGICO')",
                    rs -> {
                        while (rs.next()) {
                            String categoria = rs.getString("categoria");
                            String codigo = rs.getString("codigo");
                            Long pk = rs.getLong("pk_tlista_valor");
                            if ("JORNADA".equals(categoria)) {
                                jornadaReverseMap.put(codigo, pk);
                            } else if ("MODELO_PEDAGOGICO".equals(categoria)) {
                                modeloPedagogicoReverseMap.put(codigo, pk);
                            }
                        }
                    });
            } catch (SQLException e) {
                log.error("snapshot query for tlista_valor failed", e);
            }

            try {
                runQuery(conn, "SELECT pk_tmatricula, * FROM tmatricula_socioeconomico", rs -> {
                    while (rs.next()) {
                        socio.put(rs.getLong("pk_tmatricula"), rowToMap(rs));
                    }
                });
            } catch (SQLException e) {
                log.error("snapshot query for tmatricula_socioeconomico failed", e);
            }

            try {
                runQuery(conn, "SELECT pk_tmatricula, * FROM tmatricula_promocion", rs -> {
                    while (rs.next()) {
                        promo.put(rs.getLong("pk_tmatricula"), rowToMap(rs));
                    }
                });
            } catch (SQLException e) {
                log.error("snapshot query for tmatricula_promocion failed", e);
            }

            try {
                runQuery(conn,
                    "SELECT pk_tsede_usuario, fk_tsede, fk_trol, fk_tusuario, "
                        + "fk_tlv_jornada, orden FROM tsede_usuario",
                    rs -> {
                        while (rs.next()) {
                            sedeUsuario.put(
                                rs.getLong("pk_tsede_usuario"),
                                new SnapshotCache.SedeUsuarioRow(
                                    rs.getLong("fk_tsede"),
                                    rs.getLong("fk_trol"),
                                    rs.getLong("fk_tusuario"),
                                    rs.getString("fk_tlv_jornada"),
                                    rs.getInt("orden")));
                        }
                    });
            } catch (SQLException e) {
                log.error("snapshot query for tsede_usuario failed", e);
            }

            try {
                runQuery(conn, "SELECT pk_periodo_academico, * FROM tcriterio_evaluacion", rs -> {
                    while (rs.next()) {
                        criterio.put(rs.getLong("pk_periodo_academico"), rowToMap(rs));
                    }
                });
            } catch (SQLException e) {
                log.error("snapshot query for tcriterio_evaluacion failed", e);
            }

            try {
                runQuery(conn,
                    "SELECT pk_tgrupo, fk_tlv_jornada, fk_tlv_modelo_pedagogico FROM tgrupo",
                    rs -> {
                        while (rs.next()) {
                            grupo.put(rs.getLong("pk_tgrupo"), rowToMap(rs));
                        }
                    });
            } catch (SQLException e) {
                log.error("snapshot query for tgrupo failed", e);
            }

            log.info(
                "Hydrated snapshots: {} socio, {} promo, {} sedeUsuario, {} criterio, "
                    + "{} grupo",
                socio.size(), promo.size(), sedeUsuario.size(),
                criterio.size(), grupo.size());
        } catch (SQLException e) {
            // Connection-level failure (DataSource unreachable, auth error).
            // Logged once; no point continuing per-query retry because every
            // query shares the same broken connection.
            log.error("Snapshot hydration connection failed", e);
        }

        return new SnapshotCache(
            Map.copyOf(socio),
            Map.copyOf(promo),
            Map.copyOf(sedeUsuario),
            Map.copyOf(criterio),
            Map.copyOf(grupo),
            Map.copyOf(jornadaReverseMap),
            Map.copyOf(modeloPedagogicoReverseMap),
            Map.copyOf(tlistaValorIndex));
    }

    private void runQuery(Connection conn, String sql, SqlConsumer<ResultSet> handler)
            throws SQLException {
        try (PreparedStatement ps = conn.prepareStatement(sql)) {
            ps.setQueryTimeout(QUERY_TIMEOUT_SEC);
            try (ResultSet rs = ps.executeQuery()) {
                handler.accept(rs);
            }
        }
    }

    /**
     * Converts the current {@link ResultSet} row into a {@link LinkedHashMap}
     * keyed by column label. Uses the JDBC meta-data API so the iteration
     * stays in lock-step with whatever columns the SELECT exposed — safe
     * for {@code SELECT * FROM ...} where we do not want to hard-code
     * column lists (they drift across V22 sub-versions).
     */
    private Map<String, Object> rowToMap(ResultSet rs) throws SQLException {
        ResultSetMetaData md = rs.getMetaData();
        Map<String, Object> row = new LinkedHashMap<>();
        for (int i = 1; i <= md.getColumnCount(); i++) {
            row.put(md.getColumnLabel(i), rs.getObject(i));
        }
        return row;
    }

    @FunctionalInterface
    private interface SqlConsumer<T> {
        void accept(T t) throws SQLException;
    }
}
