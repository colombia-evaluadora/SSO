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
 *   <li>{@link #FUNCTION} — a {@code SELECT * FROM
 *       schema.func(...)} statement. Treated as a SELECT for
 *       JDBC purposes (the result is a ResultSet), but
 *       catalogued separately so the admin form can render the
 *       right hint.</li>
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
    FUNCTION;

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
