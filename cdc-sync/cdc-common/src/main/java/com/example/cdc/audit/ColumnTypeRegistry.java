package com.example.cdc.audit;

import com.fasterxml.jackson.databind.ObjectMapper;

import java.io.IOException;
import java.io.InputStream;
import java.util.Collections;
import java.util.HashMap;
import java.util.Map;
import java.util.Set;

/**
 * Static type metadata loaded from a JSON resource. The JSON shape is
 * documented in spec §6. The registry is immutable after construction.
 */
public final class ColumnTypeRegistry {

    private static final ObjectMapper MAPPER = new ObjectMapper();

    private final Map<String, Map<String, Slot>> tableToColumns;

    private ColumnTypeRegistry(Map<String, Map<String, Slot>> tableToColumns) {
        this.tableToColumns = tableToColumns;
    }

    public static ColumnTypeRegistry loadFromClasspath(String resourceName) {
        try (InputStream in = ColumnTypeRegistry.class
                .getClassLoader()
                .getResourceAsStream(resourceName)) {
            if (in == null) {
                throw new IllegalStateException(
                        "Resource not found on classpath: " + resourceName);
            }
            ColumnTypes parsed = MAPPER.readValue(in, ColumnTypes.class);
            return build(parsed);
        } catch (IOException e) {
            throw new IllegalStateException(
                    "Failed to load column-types resource " + resourceName, e);
        }
    }

    private static ColumnTypeRegistry build(ColumnTypes parsed) {
        Map<String, Map<String, Slot>> out = new HashMap<>();
        if (parsed.tables() != null) {
            for (Map.Entry<String, ColumnTypes.Table> tableEntry
                    : parsed.tables().entrySet()) {
                Map<String, Slot> cols = new HashMap<>();
                ColumnTypes.Table t = tableEntry.getValue();
                if (t.columns() != null) {
                    for (Map.Entry<String, ColumnTypes.Column> colEntry
                            : t.columns().entrySet()) {
                        cols.put(colEntry.getKey().toLowerCase(),
                                Slot.valueOf(colEntry.getValue().slot().toUpperCase()));
                    }
                }
                out.put(tableEntry.getKey().toLowerCase(), cols);
            }
        }
        return new ColumnTypeRegistry(Collections.unmodifiableMap(out));
    }

    public Slot slotFor(String tabla, String columna) {
        Map<String, Slot> cols = tableToColumns.get(tabla.toLowerCase());
        if (cols == null) return Slot.NONE;
        Slot s = cols.get(columna.toLowerCase());
        return s == null ? Slot.NONE : s;
    }

    public Set<String> tables() {
        return tableToColumns.keySet();
    }
}
