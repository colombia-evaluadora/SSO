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

    /**
     * Curated list of academico-schema tables this stage reverse-syncs
     * onto. Kept in declaration order; the same names appear (uppercased)
     * in {@code table-routing.yaml} as the {@code oracle_table} values
     * for every Phase 3 L4-L6 entry. Adding a table here is part of the
     * Phase 4 config change — do NOT add an entry here without also
     * landing its routing-YAML counterpart (and vice versa).
     *
     * <p>{@link #validateSchema} skips a table gracefully when its
     * fetch raises so a single missing table does not block startup
     * (mostly useful for the L7+ tables whose Oracle destinations are
     * gated off via {@code cdc.tables.*.enabled=false}).
     */
    private static final List<String> CRITICAL_TABLES = List.of(
            // L0 catálogos
            "TPAIS", "TSECTOR", "TTIPO_DOCUMENTO", "TJORNADA", "TCARACTER",
            "TCAPACIDAD", "TGRUPO_ETNICO", "TFORMATO_CALIFICACION",
            "TMODELO_PEDAGOGICO", "TMODELO_CALIFICACION",
            // L2/L3 personas
            "TESTUDIANTE", "TFUNCIONARIO", "TPADRE", "TUSUARIO",
            // L4 establecimiento
            "TESTABLECIMIENTO", "TSEDE", "TARCHIVO", "TANO_LECTIVO",
            "TAREA_ASIGNATURA", "TENTE_ESTABLECIMIENTO", "TSEDE_CONVENIO",
            "TSEDE_NIVEL", "TROL", "TSEDE_USUARIO", "TENTE_USUARIO",
            "TMENU", "TROL_MENU", "TUSUARIO_ROL_PERMISO",
            // L5 académico
            "TPERIODO_ACADEMICO", "TPERIODO_ACADEMICO_CONFIG", "TGRADO",
            "TGRUPO", "TENFASIS", "TDESCANSOS", "TCOMPORTAMIENTO",
            "TASIGNATURA", "TASIGNATURA_PLAN", "TPLAN",
            "TCRITERIO_EVALUACION", "TCRITERIO_PROMOCION",
            // L6 matrícula
            "TMATRICULA", "TINSCRIPCION", "TPREMATRICULA",
            "TMATRICULA_SOCIOECONOMICO", "TMATRICULA_PROMOCION",
            "TTRASLADO_ESTUDIANTE", "TTRASLADO_MATRICULA",
            "TACTA_GRADO", "TACTA_GRADO_DETALLE", "TDIPLOMA",
            "TDIPLOMA_DETALLE", "TSEDE_CONVENIO_MATRICULA",
            // L7+ retrocompat (reverse-sync of late additions to PG)
            "TACTIVIDAD", "TACTIVIDAD_NOTA"
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