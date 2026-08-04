package com.example.cdc.worker.pipeline;

import com.example.cdc.audit.ColumnTypeRegistry;
import com.example.cdc.audit.Slot;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.math.BigDecimal;
import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.time.format.DateTimeParseException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Projects a raw Debezium row into a typed map matching the JSON slots
 * declared in audit_log.fila_new / fila_old.
 *
 * Algorithm (spec §5):
 *   for each (col, val) in rawRow, ordered by rawRow insertion order:
 *     slot = registry.slotFor(tabla, col)
 *     if slot == NONE → put into dynamic part
 *     else if slot == PADRE_ID_JSON → push (col, val) into fk list
 *     else if the slot is unclaimed → coerce and put into slot
 *     else (slot already claimed) → put into dynamic part under original name
 *
 * Type coercion (spec §8): raw Debezium values are coerced to the
 * representation ClickHouse expects for the declared JSON slot.
 * - fecha_ts (DateTime64): Long epoch-millis -> ISO-8601 String (ClickHouse
 *   parses integer DateTime as epoch SECONDS, not millis, so a raw Long
 *   would shift the value by 1000x and land ~273 years in the future).
 * - fecha (Date): java.sql.Date or ISO-8601 String -> ISO date String.
 * - decimal (Decimal18,4): Number or numeric String -> BigDecimal.
 * - pk_t, numero (Int64): Number or numeric String -> Long.
 * - booleano_sn (String S/N): Boolean, Number, or String -> "S"/"N".
 * - codigo, valor, nombre, texto (String): toString().
 * Unparseable values are written as null in the claimed typed slot and log
 * at WARN level; slot collisions, not coercion failures, use the dynamic part.
 */
public class JsonTypedRowBuilder {

    private static final Logger log =
            LoggerFactory.getLogger(JsonTypedRowBuilder.class);

    // ClickHouse DateTime64(3, 'UTC') inside a JSON column rejects
    // ISO_INSTANT strings (with trailing 'Z'). Use LOCAL_DATE_TIME shape
    // without timezone marker; the column is declared UTC so ClickHouse
    // interprets the value as UTC.
    private static final DateTimeFormatter DATE_TS_FORMAT =
            DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS");
    private static final DateTimeFormatter DATE_FORMAT =
            DateTimeFormatter.ofPattern("yyyy-MM-dd");

    private final ColumnTypeRegistry registry;

    public JsonTypedRowBuilder(ColumnTypeRegistry registry) {
        this.registry = registry;
    }

    public Map<String, Object> build(String tabla, Map<String, Object> rawRow) {
        if (rawRow == null || rawRow.isEmpty()) return new LinkedHashMap<>();

        Map<String, Object> out = new LinkedHashMap<>();
        List<Map<String, Object>> fks = null; // lazy
        Set<Slot> claimed = new java.util.HashSet<>();

        for (Map.Entry<String, Object> e : rawRow.entrySet()) {
            String col = e.getKey();
            Object val = e.getValue();
            Slot slot = registry.slotFor(tabla, col);

            if (slot == Slot.NONE) {
                out.put(col, val);
                continue;
            }
            if (slot == Slot.PADRE_ID_JSON) {
                if (fks == null) fks = new ArrayList<>();
                fks.add(fkEntry(col, val));
                continue;
            }
            // Scalar slot. First-wins (spec §5.1).
            if (claimed.add(slot)) {
                out.put(slot.code(), coerce(val, slot));
                if (slot == Slot.PK_T) {
                    // Also keep the original name so AuditRecord.extractPk
                    // (which scans keys starting with "pk_") continues to work.
                    out.put(col, val);
                }
            } else {
                out.put(col, val);
            }
        }

        if (fks != null) {
            out.put(Slot.PADRE_ID_JSON.code(), fks);
        }
        return out;
    }

    private static Object coerce(Object val, Slot slot) {
        if (val == null) return null;
        try {
            return switch (slot) {
                case FECHA_TS -> val instanceof Instant i
                        ? DATE_TS_FORMAT.format(i.atZone(ZoneOffset.UTC))
                        : val instanceof Long l
                            ? DATE_TS_FORMAT.format(Instant.ofEpochMilli(l)
                                    .atZone(ZoneOffset.UTC))
                        : val instanceof String s
                            ? DATE_TS_FORMAT.format(Instant.parse(s)
                                    .atZone(ZoneOffset.UTC))
                        : val instanceof LocalDateTime ldt
                            ? DATE_TS_FORMAT.format(ldt.atZone(ZoneOffset.UTC))
                        : val instanceof OffsetDateTime odt
                            ? DATE_TS_FORMAT.format(odt.toLocalDateTime())
                        : val;
                case FECHA -> val instanceof java.sql.Date d
                        ? DATE_FORMAT.format(d.toLocalDate())
                        : val instanceof LocalDate ld
                            ? DATE_FORMAT.format(ld)
                        : val instanceof Number n
                            ? DATE_FORMAT.format(LocalDate.ofEpochDay(n.longValue()))
                        : val instanceof String s
                            ? DATE_FORMAT.format(LocalDate.parse(s))
                        : val;
                case DECIMAL -> val instanceof BigDecimal bd ? bd
                        : val instanceof Number n ? new BigDecimal(n.toString())
                        : val instanceof String s ? new BigDecimal(s)
                        : val;
                case PK_T, NUMERO -> val instanceof Number n ? n.longValue()
                        : val instanceof String s ? Long.parseLong(s)
                        : val;
                case BOOLEANO_SN -> val instanceof Boolean b ? (b ? "S" : "N")
                        : val instanceof Number n ? (n.intValue() == 0 ? "N" : "S")
                        : val instanceof String s ? parseBooleanoSn(s)
                        : val;
                case CODIGO, VALOR, NOMBRE, TEXTO -> val.toString();
                default -> val;
            };
        } catch (DateTimeParseException | NumberFormatException e) {
            log.warn("coerce failed for slot {} value '{}' ({}): {}",
                    slot, val, val.getClass().getSimpleName(), e.getMessage());
            return null;
        }
    }

    private static String parseBooleanoSn(String s) {
        String norm = s.trim().toUpperCase();
        return switch (norm) {
            case "S", "SI", "Y", "YES", "TRUE", "1", "T" -> "S";
            case "N", "NO", "FALSE", "0", "F" -> "N";
            default -> s; // pass through unchanged
        };
    }

    private static Map<String, Object> fkEntry(String col, Object val) {
        Map<String, Object> entry = new LinkedHashMap<>();
        entry.put("name", col);
        entry.put("value", val == null ? null : String.valueOf(val));
        return entry;
    }
}
