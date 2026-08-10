package com.co.eurekatic.common.entity;

/**
 * How {@code query-service} executes a {@link Query} row.
 *
 * <p>The string values match the {@code EXECUTION_MODE} column
 * in the {@code QUERY} table (V28) and the CHECK constraint
 * enforced by Postgres. Storing as VARCHAR (not Java enum
 * ordinal) lets an admin update the column directly without
 * going through the enum-trap that bit the legacy code.
 *
 * <ul>
 *   <li>{@link #SELECT} — a standard {@code SELECT} (or
 *       {@code WITH}) statement. The JDBC layer calls
 *       {@code JdbcTemplate.query()} and the
 *       {@code rejectIfMutating} guard enforces the read-only
 *       invariant.</li>
 *   <li>{@link #PROCEDURE} — a {@code CALL schema.proc(...)}
 *       statement. The procedure may use {@code RETURN QUERY}
 *       (PL/pgSQL) to return rows; the JDBC layer still calls
 *       {@code JdbcTemplate.query()} but the SELECT-only guard
 *       is bypassed.</li>
 *   <li>{@link #FUNCTION} — histórico. Se ejecutaba y validaba
 *       exactamente igual que {@link #SELECT}, así que V32
 *       convirtió las filas existentes y el formulario dejó de
 *       ofrecerlo. Se conserva en el enum para que un valor
 *       antiguo en la columna no deje de parsear.</li>
 *   <li>{@link #DML} — V33. Un {@code INSERT} o {@code UPDATE}
 *       escrito directamente. No pasa por {@code rejectIfMutating}
 *       y se ejecuta con {@code JdbcTemplate.update()}, así que
 *       devuelve {@code rowsAffected} en vez de filas. Sólo puede
 *       existir en filas atadas a {@code POST} o {@code PUT}: el
 *       permiso va atado al modo, no al verbo, para que conceder
 *       DML no desproteja a las filas {@code SELECT} que ya
 *       existen.</li>
 * </ul>
 *
 * <p>The string form is what travels in JSON and in the DB; the
 * enum is a typed convenience in the Java layer. Use
 * {@link #fromString(String)} for tolerant parsing (unknown →
 * {@link #SELECT} as a safe default).
 */
public enum ExecutionMode {
    SELECT,
    PROCEDURE,
    FUNCTION,
    DML;

    public static final String DEFAULT = "SELECT";

    public static ExecutionMode fromString(String raw) {
        if (raw == null || raw.isBlank()) return SELECT;
        try {
            return ExecutionMode.valueOf(raw.trim().toUpperCase());
        } catch (IllegalArgumentException e) {
            // Unknown value — fall back to SELECT so a bad row
            // doesn't crash every request; the SELECT-only guard
            // will surface the actual mismatch as a 400.
            return SELECT;
        }
    }
}
