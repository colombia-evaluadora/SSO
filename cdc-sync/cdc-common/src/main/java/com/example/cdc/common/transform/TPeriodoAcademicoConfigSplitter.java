package com.example.cdc.common.transform;

import com.example.cdc.common.event.CdcEvent;
import com.example.cdc.common.snapshot.SnapshotCache;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Inverts the split that the forward Oracle → PG migration applied to the
 * academic period configuration.
 *
 * <p>Postgres keeps {@code tperiodo_academico} plus the criteria rows in a
 * separate {@code tcriterio_evaluacion} table; the legacy Oracle schema
 * expects one row in {@code TPERIODO_ACADEMICO} and a sibling row in
 * {@code TPERIODO_ACADEMICO_CONFIG} that inlines the criteria plus the
 * schedule defaults.
 *
 * <p>Per-event behaviour:
 * <ul>
 *   <li>{@code tperiodo_academico}: produces one or two splits. If the
 *       hydrated {@link SnapshotCache#criterio()} map has an entry for the
 *       period PK, the splitter emits {@code TPERIODO_ACADEMICO_CONFIG}
 *       first (with {@code HORA_INICIO}, {@code HORA_FIN},
 *       {@code BLOQUES_POR_DEFECTO} and the inlined criteria) followed by
 *       {@code TPERIODO_ACADEMICO} (with {@code FECHA_LIMITE_MATRICULA}
 *       renamed to {@code FECHA_LIMITE} and {@code FK_TLV_JORNADA} renamed
 *       to {@code FK_TJORNADA}). Otherwise only the {@code TPERIODO_ACADEMICO}
 *       split is emitted.</li>
 *   <li>{@code tcriterio_evaluacion}: produces a single
 *       {@code TPERIODO_ACADEMICO_CONFIG} UPSERT keyed by
 *       {@code FK_TPERIODO_ACADEMICO} (overwriting the previous config row
 *       for that period).</li>
 * </ul>
 *
 * <p>Null-safe: a {@code null} cache is treated as {@link SnapshotCache#empty()}.
 */
public class TPeriodoAcademicoConfigSplitter {

    private static final String TABLE_PERIODO = "tperiodo_academico";
    private static final String TABLE_CRITERIO = "tcriterio_evaluacion";

    private static final String COL_PK_PERIODO = "pk_periodo_academico";
    private static final String COL_HORA_INICIO = "hora_inicio";
    private static final String COL_HORA_FIN = "hora_fin";
    private static final String COL_BLOQUES = "bloques_por_defecto";
    private static final String COL_FECHA_LIMITE_MATRICULA = "fecha_limite_matricula";
    private static final String COL_FK_TLV_JORNADA = "fk_tlv_jornada";

    private static final String COL_PK_CRITERIO = "pk_criterio";
    private static final String COL_FK_PERIODO_ACADEMICO = "fk_periodo_academico";
    private static final String COL_MINIMA = "minima";
    private static final String COL_MAXIMA = "maxima";

    private static final String ORACLE_TABLE_PERIODO = "TPERIODO_ACADEMICO";
    private static final String ORACLE_TABLE_CONFIG = "TPERIODO_ACADEMICO_CONFIG";
    private static final String ORACLE_PK_PERIODO = "PK_TPERIODO_ACADEMICO";
    private static final String ORACLE_FK_PERIODO = "FK_TPERIODO_ACADEMICO";
    private static final String ORACLE_HORA_INICIO = "HORA_INICIO";
    private static final String ORACLE_HORA_FIN = "HORA_FIN";
    private static final String ORACLE_BLOQUES = "BLOQUES_POR_DEFECTO";
    private static final String ORACLE_FECHA_LIMITE = "FECHA_LIMITE";
    private static final String ORACLE_FK_TJORNADA = "FK_TJORNADA";
    private static final String ORACLE_MINIMA = "MINIMA";
    private static final String ORACLE_MAXIMA = "MAXIMA";
    private static final String ORACLE_PK_CRITERIO = "PK_CRITERIO";

    private final SnapshotCache cache;

    public TPeriodoAcademicoConfigSplitter(SnapshotCache cache) {
        this.cache = cache != null ? cache : SnapshotCache.empty();
    }

    public List<Split> apply(CdcEvent event) {
        String table = event.tableName();
        if (TABLE_PERIODO.equals(table)) {
            return splitPeriodo(event.after());
        }
        if (TABLE_CRITERIO.equals(table)) {
            return List.of(criterioToConfig(event.after()));
        }
        throw new IllegalArgumentException("Unsupported table for TPeriodoAcademicoConfigSplitter: " + table);
    }

    private List<Split> splitPeriodo(Map<String, Object> row) {
        if (row == null) {
            throw new IllegalArgumentException("tperiodo_academico event without after-row");
        }
        Long pk = toLong(row.get(COL_PK_PERIODO));

        Map<String, Object> configRow = new LinkedHashMap<>();
        configRow.put(ORACLE_FK_PERIODO, pk);
        copyIfPresent(configRow, ORACLE_HORA_INICIO, row.get(COL_HORA_INICIO));
        copyIfPresent(configRow, ORACLE_HORA_FIN, row.get(COL_HORA_FIN));
        copyIfPresent(configRow, ORACLE_BLOQUES, row.get(COL_BLOQUES));

        Map<String, Object> criterio = cache.criterio() != null ? cache.criterio().get(pk) : null;
        if (criterio != null) {
            configRow.putAll(criterio);
        }

        Map<String, Object> periodoRow = new LinkedHashMap<>(row);
        periodoRow.remove(COL_HORA_INICIO);
        periodoRow.remove(COL_HORA_FIN);
        periodoRow.remove(COL_BLOQUES);
        Object flm = periodoRow.remove(COL_FECHA_LIMITE_MATRICULA);
        if (flm != null) {
            periodoRow.put(ORACLE_FECHA_LIMITE, flm);
        }
        Object jornada = periodoRow.remove(COL_FK_TLV_JORNADA);
        if (jornada != null) {
            periodoRow.put(ORACLE_FK_TJORNADA, jornada);
        }

        List<Split> out = new ArrayList<>(2);
        if (criterio != null || configRow.size() > 1) {
            out.add(new Split(ORACLE_TABLE_CONFIG, ORACLE_FK_PERIODO, configRow));
        }
        out.add(new Split(ORACLE_TABLE_PERIODO, ORACLE_PK_PERIODO, periodoRow));
        return out;
    }

    private Split criterioToConfig(Map<String, Object> row) {
        if (row == null) {
            throw new IllegalArgumentException("tcriterio_evaluacion event without after-row");
        }
        Map<String, Object> configRow = new LinkedHashMap<>();
        configRow.put(ORACLE_FK_PERIODO, row.get(COL_FK_PERIODO_ACADEMICO));
        configRow.put(ORACLE_MINIMA, row.get(COL_MINIMA));
        configRow.put(ORACLE_MAXIMA, row.get(COL_MAXIMA));
        configRow.put(ORACLE_PK_CRITERIO, row.get(COL_PK_CRITERIO));
        return new Split(ORACLE_TABLE_CONFIG, ORACLE_FK_PERIODO, configRow);
    }

    private static void copyIfPresent(Map<String, Object> target, String key, Object value) {
        if (value != null) {
            target.put(key, value);
        }
    }

    private static Long toLong(Object value) {
        if (value == null) return null;
        if (value instanceof Number n) return n.longValue();
        try {
            return Long.parseLong(value.toString());
        } catch (NumberFormatException ignored) {
            return null;
        }
    }

    public record Split(String oracleTable, String pkColumn, Map<String, Object> row) {
    }
}