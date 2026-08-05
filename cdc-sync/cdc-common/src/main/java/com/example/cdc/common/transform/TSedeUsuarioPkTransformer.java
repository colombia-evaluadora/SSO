package com.example.cdc.common.transform;

import com.example.cdc.common.event.CdcEvent;
import com.example.cdc.common.event.Operation;
import com.example.cdc.common.snapshot.SnapshotCache;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Converts a PostgreSQL {@code tsede_usuario} event into the Oracle composite
 * primary-key row expected by the legacy {@code TSEDE_USUARIO} table.
 *
 * <p>PG uses a synthetic IDENTITY surrogate ({@code pk_tsede_usuario}) plus the
 * natural triple ({@code fk_tsede, fk_trol, fk_tusuario}) together with the
 * jornada lookup code ({@code fk_tlv_jornada}). Oracle, in contrast, has
 * dropped the surrogate and uses the natural triple as its primary key, with
 * a real FK into the jornada catalogue ({@code fk_tjornada}).
 *
 * <p>The transformer relies on the bulk-hydrated {@link SnapshotCache} to
 * recover the composite PK fields from the surrogate id. The cache miss path
 * is a soft failure: WARN + empty map, never a hot-path PG lookup.
 *
 * <p>For {@code op='d'} events the transformer returns an empty map so the
 * caller (the Oracle reverse stage) can perform the DELETE using the
 * composite PK extracted from the snapshot.
 */
@Component
public class TSedeUsuarioPkTransformer {

    private static final Logger log = LoggerFactory.getLogger(TSedeUsuarioPkTransformer.class);

    private final SnapshotCache cache;

    public TSedeUsuarioPkTransformer() {
        this(SnapshotCache.empty());
    }

    public TSedeUsuarioPkTransformer(SnapshotCache cache) {
        this.cache = cache != null ? cache : SnapshotCache.empty();
    }

    /**
     * Returns the Oracle row map for the supplied event. The caller is expected
     * to route the result to {@code OracleJdbcWriter.merge("TSEDE_USUARIO",
     * "(FK_TSEDE, FK_TROL, FK_TUSUARIO)", row)} (multi-column ON).
     *
     * @param event the CDC event for {@code tsede_usuario}
     * @return the Oracle row map, or an empty map when the event must be
     *         skipped (delete, or snapshot miss)
     */
    public Map<String, Object> apply(CdcEvent event) {
        if (event == null || event.op() == Operation.DELETE) {
            return Map.of();
        }

        Map<String, Object> row = event.after();
        if (row == null) {
            return Map.of();
        }

        Long pk = toLong(row.get("pk_tsede_usuario"));
        if (pk == null) {
            log.warn("tsede_usuario event missing pk_tsede_usuario; skipping");
            return Map.of();
        }

        SnapshotCache.SedeUsuarioRow snap = cache.sedeUsuario().get(pk);
        if (snap == null) {
            log.warn("Snapshot miss for pk_tsede_usuario={}; skipping Oracle write", pk);
            return Map.of();
        }

        Map<String, Object> out = new LinkedHashMap<>();
        out.put("FK_TSEDE", snap.fkSede());
        out.put("FK_TROL", snap.fkRol());
        out.put("FK_TUSUARIO", snap.fkUsuario());
        out.put("FK_TJORNADA", cache.jornadaReverseMap().get(snap.fkLvJornada()));
        out.put("ORDEN", snap.orden());
        return out;
    }

    private static Long toLong(Object value) {
        if (value == null) return null;
        if (value instanceof Number number) return number.longValue();
        if (value instanceof String string) {
            try {
                return Long.parseLong(string);
            } catch (NumberFormatException ignored) {
                return null;
            }
        }
        return null;
    }
}
