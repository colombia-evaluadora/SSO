package com.example.cdc.common.transform;

import com.example.cdc.common.event.CdcEvent;
import com.example.cdc.common.snapshot.SnapshotCache;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Optional;

/**
 * Reconstructs the legacy Oracle {@code TMATRICULA} row from the PostgreSQL
 * main row plus its optional promotion and socioeconomic snapshots, and stamps
 * the discriminator {@code fk_tlv_tipo_matricula} on the
 * {@code TINSCRIPCION}/{@code TPREMATRICULA} sub-paths.
 *
 * <p>Snapshots are looked up in {@link SnapshotCache#matriculaSocio()} and
 * {@link SnapshotCache#matriculaPromo()}, both hydrated at worker boot by
 * {@code SnapshotHydrator}. The transformer is intentionally read-only: if a
 * snapshot row arrives whose matricula is absent from the cache, a WARN is
 * logged and the original row is returned unchanged (hot-path NEVER queries PG).
 *
 * <p>Tables handled by this transformer (per spec §3.1):
 * <ul>
 *   <li>{@code tmatricula} — merge main row + socio snapshot + (when
 *       {@code promocion_anticipada='S'}) promo snapshot.</li>
 *   <li>{@code tinscripcion} — stamp {@code fk_tlv_tipo_matricula='Inscripcion'}.</li>
 *   <li>{@code tprematricula} — stamp {@code fk_tlv_tipo_matricula='Prematricula'}.</li>
 *   <li>{@code tmatricula_socioeconomico}/{@code tmatricula_promocion} — pass
 *       through; WARN on cache miss against the parent matricula.</li>
 * </ul>
 *
 * <p>This class is no longer a {@code @Component} — Phase 3's
 * {@code RetrocompatConfig} instantiates it with the hydrated cache. The
 * {@link #apply(CdcEvent, OperationContext)} shim is preserved for the legacy
 * {@code OracleReverseStage} wiring until Phase 3 retires it.
 */
public class TMatriculaConsolidator implements Transformer {

    private static final Logger log = LoggerFactory.getLogger(TMatriculaConsolidator.class);

    private final SnapshotCache cache;

    public TMatriculaConsolidator(SnapshotCache cache) {
        this.cache = cache != null ? cache : SnapshotCache.empty();
    }

    /**
     * Compatibility overload for the {@link Transformer} interface used by the
     * pre-Phase-3 {@code OracleReverseStage}. Wraps the new apply() result in
     * {@code Optional.ofNullable} so the legacy chain keeps working until
     * {@code RetrocompatConfig} replaces it.
     */
    @Override
    public Optional<Map<String, Object>> apply(CdcEvent event, OperationContext ctx) {
        return Optional.ofNullable(apply(event, (CdcEvent.Context) null));
    }

    /**
     * Consolidates a {@link CdcEvent} for one of the L6 tables handled by this
     * transformer. Returns the row that should be persisted to Oracle (or
     * {@code null} when the event has no payload to merge).
     */
    public Map<String, Object> apply(CdcEvent event, CdcEvent.Context ctx) {
        String table = event.tableName();
        Map<String, Object> row = "d".equals(event.op().code()) ? event.before() : event.after();
        if (row == null) return null;

        return switch (table) {
            case "tmatricula" -> consolidateMatricula(row);
            case "tinscripcion" -> consolidateWithType(row, "Inscripcion");
            case "tprematricula" -> consolidateWithType(row, "Prematricula");
            case "tmatricula_socioeconomico" -> updateSnapshot(row, cache.matriculaSocio());
            case "tmatricula_promocion" -> updateSnapshot(row, cache.matriculaPromo());
            default -> row;
        };
    }

    private Map<String, Object> consolidateMatricula(Map<String, Object> row) {
        Long pk = toLong(row.get("pk_tmatricula"));
        Map<String, Object> merged = new LinkedHashMap<>(row);
        Map<String, Object> socio = cache.matriculaSocio().get(pk);
        if (socio != null) merged.putAll(socio);
        if ("S".equals(row.get("promocion_anticipada"))) {
            Map<String, Object> promo = cache.matriculaPromo().get(pk);
            if (promo != null) merged.putAll(promo);
        }
        return merged;
    }

    private Map<String, Object> consolidateWithType(Map<String, Object> row, String tipo) {
        Map<String, Object> merged = new LinkedHashMap<>(row);
        merged.put("fk_tlv_tipo_matricula", tipo);
        return merged;
    }

    /**
     * Pass-through for snapshot-source tables ({@code tmatricula_socioeconomico},
     * {@code tmatricula_promocion}). The cache is read-only — hydrated at boot —
     * so this method only checks coverage and emits a WARN when the parent
     * matricula is not present, leaving the row unchanged.
     */
    private Map<String, Object> updateSnapshot(Map<String, Object> row,
                                               Map<Long, Map<String, Object>> snapshotMap) {
        Long pk = toLong(row.get("pk_tmatricula"));
        if (pk == null || !snapshotMap.containsKey(pk)) {
            log.warn("Snapshot miss for pk_tmatricula={}", pk);
        }
        return row;
    }

    private static Long toLong(Object o) {
        if (o == null) return null;
        if (o instanceof Number n) return n.longValue();
        try {
            return Long.parseLong(o.toString());
        } catch (NumberFormatException e) {
            return null;
        }
    }
}
