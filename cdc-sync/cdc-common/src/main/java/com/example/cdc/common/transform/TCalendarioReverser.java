package com.example.cdc.common.transform;

import com.example.cdc.common.event.CdcEvent;
import com.example.cdc.common.snapshot.SnapshotCache;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Optional;

/**
 * Splits the consolidated PG {@code FK_TPERIODO_ACADEMICO} on a {@code TCALENDARIO}
 * event back into the Oracle native ({@code FK_TANO_LECTIVO}, {@code FK_TSEDE})
 * pair via {@link SnapshotCache#calendarioSplit} hydrated at boot.
 *
 * <p>Mirrors the {@code TCALENDARIO->TCALENDARIO} forward transform in
 * {@code db-migrations/migration/config/table_plan.yaml:900} (which fuses the
 * pair into a single periodo FK during the one-shot Oracle→PG seed). Without
 * this reverser, an INSERT/UPDATE on PG would only carry the periodo FK and
 * Oracle's
 * {@code TCalendario(FK_TANO_LECTIVO, FK_TSEDE)} NOT NULL pair would be NULL.
 *
 * <p>Misses (no split for the periodo PK) emit a WARN and write {@code null}
 * for both Oracle FKs, never throw. Same fail-soft contract as
 * {@link TGrupoFkRewriter}.
 */
public class TCalendarioReverser implements Transformer {

    private static final Logger log = LoggerFactory.getLogger(TCalendarioReverser.class);

    private final SnapshotCache cache;

    public TCalendarioReverser() {
        this(SnapshotCache.empty());
    }

    public TCalendarioReverser(SnapshotCache cache) {
        this.cache = cache != null ? cache : SnapshotCache.empty();
    }

    @Override
    public Optional<Map<String, Object>> apply(CdcEvent event, OperationContext ctx) {
        Map<String, Object> row = event.after();
        if (row == null) return Optional.of(Map.of());

        Map<String, Object> out = new LinkedHashMap<>(row);
        Long periodo = coerceLong(out.get("fk_tperiodo_academico"));
        if (periodo == null) {
            log.warn("TCalendarioReverser: missing fk_tperiodo_academico — Oracle FKs null");
            out.put("FK_TANO_LECTIVO", null);
            out.put("FK_TSEDE", null);
        } else {
            SnapshotCache.CalendarioSplit split = cache.calendarioSplit().get(periodo);
            if (split == null) {
                log.warn("TCalendarioReverser: snapshot miss for pk_tperiodo_academico={} — Oracle FKs null",
                    periodo);
                out.put("FK_TANO_LECTIVO", null);
                out.put("FK_TSEDE", null);
            } else {
                out.put("FK_TANO_LECTIVO", split.fkAnoLectivo());
                out.put("FK_TSEDE", split.fkSede());
            }
        }
        out.remove("fk_tperiodo_academico");
        out.remove("FK_TPERIODO_ACADEMICO");
        return Optional.of(out);
    }

    private static Long coerceLong(Object v) {
        if (v == null) return null;
        if (v instanceof Number n) return n.longValue();
        try {
            return Long.parseLong(v.toString());
        } catch (NumberFormatException nfe) {
            return null;
        }
    }
}
