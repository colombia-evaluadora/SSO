package com.example.cdc.common.transform;

import com.example.cdc.common.event.CdcEvent;
import org.springframework.stereotype.Component;

import java.util.HashMap;
import java.util.Map;
import java.util.Optional;

/**
 * Reconstructs the legacy Oracle TMATRICULA row from the PostgreSQL main row
 * and its optional promotion and socioeconomic snapshots.
 *
 * <p>MVP: snapshot rows are supplied through an in-memory cache keyed by each
 * snapshot primary key. The wiring layer can replace this cache with a
 * hydrated implementation in a later task.
 */
@Component
public class TMatriculaConsolidator implements Transformer {

    private static final String PROMOTION_FK = "fk_tmatricula_promocion";
    private static final String SOCIOECONOMIC_FK = "fk_tmatricula_socioeconomico";

    private final Map<Long, Map<String, Object>> snapshotCache;
    private final ColumnRenamer columnRenamer = new ColumnRenamer();
    private final TypeMapper typeMapper = new TypeMapper();

    public TMatriculaConsolidator() {
        this(Map.of());
    }

    public TMatriculaConsolidator(Map<Long, Map<String, Object>> snapshotCache) {
        this.snapshotCache = snapshotCache;
    }

    @Override
    public Optional<Map<String, Object>> apply(CdcEvent event, OperationContext ctx) {
        Map<String, Object> row = event.after();
        if (row == null) return Optional.empty();

        Map<String, Object> consolidated = new HashMap<>(row);
        mergeSnapshot(consolidated, row.get(PROMOTION_FK));
        mergeSnapshot(consolidated, row.get(SOCIOECONOMIC_FK));

        CdcEvent consolidatedEvent = new CdcEvent(
                event.op(),
                event.before(),
                consolidated,
                event.source(),
                event.tsMs(),
                event.routingKey(),
                event.context(),
                event.message()
        );
        Map<String, Object> renamed = columnRenamer.apply(consolidatedEvent, ctx).orElse(Map.of());
        CdcEvent renamedEvent = new CdcEvent(
                event.op(),
                event.before(),
                renamed,
                event.source(),
                event.tsMs(),
                event.routingKey(),
                event.context(),
                event.message()
        );
        return typeMapper.apply(renamedEvent, ctx);
    }

    private void mergeSnapshot(Map<String, Object> consolidated, Object snapshotPk) {
        Long pk = toLong(snapshotPk);
        if (pk == null) return;

        Map<String, Object> snapshot = snapshotCache.get(pk);
        if (snapshot != null) {
            consolidated.putAll(snapshot);
        }
    }

    private static Long toLong(Object value) {
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
