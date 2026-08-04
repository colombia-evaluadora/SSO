package com.example.cdc.worker.oracle;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

import java.util.List;

/**
 * Walks a curated list of academico_test-style tables on the
 * Oracle reverse-sync target on startup and prints one INFO/WARN
 * line per table.
 *
 * <p>Gated on {@code cdc.destinations.oracle.enabled=true} so the
 * bean is NOT created (and the JDBC pool is NOT eagerly hit) when
 * the operator sets {@code CDC_DEST_ORACLE=false} — the common case
 * in dev/CI where only the ClickHouse audit sink is wired. Without
 * this gate every container boot printed a flood of
 * {@code "Tabla Oracle TMODELO_PEDAGOGICO no accesible"} warnings
 * because the Oracle JDBC URL was the localhost testcontainer default
 * and the broker had nothing to talk to.
 */
@Component
@ConditionalOnProperty(value = "cdc.destinations.oracle.enabled", havingValue = "true", matchIfMissing = false)
public class OracleSchemaBootstrap {

    private static final Logger log = LoggerFactory.getLogger(OracleSchemaBootstrap.class);

    private static final List<String> CRITICAL_TABLES = List.of(
            "TPAIS", "TSECTOR", "TTIPO_DOCUMENTO", "TJORNADA", "TCARACTER",
            "TCAPACIDAD", "TGRUPO_ETNICO", "TFORMATO_CALIFICACION",
            "TMODELO_PEDAGOGICO", "TMODELO_CALIFICACION",
            "TESTUDIANTE", "TFUNCIONARIO", "TPADRE",
            "TUSUARIO",
            "TMATRICULA",
            "TACTIVIDAD_NOTA"
    );

    private final JdbcTemplate jdbc;

    public OracleSchemaBootstrap(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    @EventListener(ApplicationReadyEvent.class)
    public void validateSchema() {
        log.info("Validando esquema Oracle...");
        for (String table : CRITICAL_TABLES) {
            try {
                Integer count = jdbc.queryForObject(
                        "SELECT COUNT(*) FROM " + table + " WHERE ROWNUM <= 1",
                        Integer.class);
                log.info("Tabla Oracle OK: {} ({} filas en muestra)", table, count);
            } catch (Exception e) {
                log.warn("Tabla Oracle {} no accesible: {}", table, e.getMessage());
            }
        }
    }
}