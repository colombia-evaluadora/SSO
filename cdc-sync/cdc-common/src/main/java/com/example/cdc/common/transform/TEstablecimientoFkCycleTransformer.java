package com.example.cdc.common.transform;

import com.example.cdc.common.event.CdcEvent;

import java.util.ArrayList;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Resolves the TESTABLECIMIENTO/TARCHIVO foreign-key cycle while preserving
 * per-event processing. TESTABLECIMIENTO rows are first merged without the
 * cyclic FK and receive an update when their referenced TARCHIVO arrives.
 */
public class TEstablecimientoFkCycleTransformer {

    private final Map<Long, Long> pendingFkWrites = new LinkedHashMap<>();

    public Decision apply(CdcEvent event) {
        String table = event.tableName();
        return switch (table) {
            case "testablecimiento" -> handleEstablecimiento(event);
            case "tsede" -> handleSede(event);
            case "tarchivo" -> handleArchivo(event);
            default -> throw new IllegalArgumentException("Unsupported table: " + table);
        };
    }

    private Decision handleEstablecimiento(CdcEvent event) {
        Map<String, Object> row = rowFor(event);
        Map<String, Object> mergeRow = oracleColumns(row);
        Long pk = toLong(row.get("pk_testablecimiento"));
        Long fkArchivo = toLong(row.get("fk_tarchivo"));
        mergeRow.put("FK_TARCHIVO", null);
        if (pk != null && fkArchivo != null) {
            pendingFkWrites.put(pk, fkArchivo);
        }
        return new Decision(mergeRow, new LinkedHashMap<>(pendingFkWrites), List.of());
    }

    private Decision handleSede(CdcEvent event) {
        return new Decision(oracleColumns(rowFor(event)), new LinkedHashMap<>(pendingFkWrites), List.of());
    }

    private Decision handleArchivo(CdcEvent event) {
        Map<String, Object> row = rowFor(event);
        Long pkArchivo = toLong(row.get("pk_tarchivo"));
        List<DeferredUpdate> drained = new ArrayList<>();
        if (pkArchivo != null) {
            Iterator<Map.Entry<Long, Long>> it = pendingFkWrites.entrySet().iterator();
            while (it.hasNext()) {
                Map.Entry<Long, Long> pending = it.next();
                if (pkArchivo.equals(pending.getValue())) {
                    drained.add(new DeferredUpdate(pending.getKey(), pending.getValue()));
                    it.remove();
                }
            }
        }
        return new Decision(oracleColumns(row), new LinkedHashMap<>(pendingFkWrites), drained);
    }

    private static Map<String, Object> rowFor(CdcEvent event) {
        Map<String, Object> row = event.after() != null ? event.after() : event.before();
        return row == null ? Map.of() : row;
    }

    private static Map<String, Object> oracleColumns(Map<String, Object> row) {
        Map<String, Object> result = new LinkedHashMap<>();
        row.forEach((key, value) -> result.put(key.toUpperCase(), oracleValue(value)));
        return result;
    }

    private static Object oracleValue(Object value) {
        return value instanceof Number number ? number.longValue() : value;
    }

    private static Long toLong(Object value) {
        if (value == null) return null;
        if (value instanceof Number number) return number.longValue();
        try {
            return Long.parseLong(value.toString());
        } catch (NumberFormatException ignored) {
            return null;
        }
    }

    public record Decision(
            Map<String, Object> initialMerge,
            Map<Long, Long> pendingUpdates,
            List<DeferredUpdate> deferredUpdates
    ) {}

    public record DeferredUpdate(Long pkEstablecimiento, Long fkArchivo) {}
}
