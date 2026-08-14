package com.co.eurekatic.query.exception;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.web.server.ResponseStatusException;

import java.sql.SQLException;

/**
 * V32 — translates {@link SQLException}s (especially
 * PostgreSQL {@code SQLState} codes) into
 * {@link ResponseStatusException}s with sensible HTTP
 * statuses. Without this mapping, every catalog row that
 * raises a server-side error surfaces as a generic 500 +
 * the raw SQL error, which leaks schema details to the
 * client and forces operators to map codes by hand.
 *
 * <p>Mapping reference (PostgreSQL {@code errcode} table):
 * <ul>
 *   <li><b>42501</b> insufficient_privilege → 403 Forbidden.
 *       Most common case: a procedure author uses
 *       {@code RAISE EXCEPTION 'permission_denied: ...'} or
 *       the underlying role lacks GRANTs. The procedure
 *       is intentionally denying access; the catalog's
 *       pre-row auth didn't catch it because the caller
 *       has the role_query binding but the procedure does
 *       additional authz on its own.</li>
 *   <li><b>P0001</b> raise_exception → 400 Bad Request.
 *       PL/pgSQL {@code RAISE EXCEPTION 'msg'} — the
 *       procedure's explicit failure path. The message
 *       after the colon (when present) is propagated to
 *       the client so the caller sees why their invocation
 *       was rejected.</li>
 *   <li><b>P0002</b> no_data_found → 404 Not Found.
 *       PL/pgSQL's reserved code for "the row I was asked
 *       to update/delete isn't there (or isn't active)".
 *       Widespread convention across {@code academico_test}'s
 *       {@code *_actualizar}/{@code *_soft_delete}/{@code
 *       *_eliminar} procedures — e.g. {@code fn_escala_eliminar}:
 *       {@code RAISE EXCEPTION 'No existe una banda activa con
 *       PK %', p_pk USING ERRCODE = 'P0002'}. Before this case
 *       existed, P0002 matched no branch in the switch below,
 *       fell through {@link #map(SQLException)}'s catch-all,
 *       and surfaced as an opaque 500 — indistinguishable from
 *       a real server fault, and silent in the logs too (the
 *       catch-all doesn't log either, by design: it's meant for
 *       truly unrecognised states, not this common one).</li>
 *   <li><b>08000-08999</b> connection_exception →
 *       503 Service Unavailable. The backing DB is
 *       unreachable or the pool is exhausted; the client
 *       should retry.</li>
 *   <li><b>22000-22999</b> data_exception → 400 Bad Request.
 *       Wrong type, division by zero, out-of-range, etc.
 *       These are almost always client input issues.</li>
 *   <li><b>23000-23999</b> integrity_constraint_violation →
 *       409 Conflict. UNIQUE / FK / NOT NULL violations;
 *       the client should know the resource already exists
 *       or the parent row is missing.</li>
 *   <li><b>40000-40999</b> transaction_rollback → 503.
 *       Deadlocks or serialization failures; retry-safe.</li>
 *   <li><b>others</b> → 500 with the message sanitised to
 *       class+message (no SQL fragment).</li>
 * </ul>
 *
 * <p>The PostgreSQL-specific mapping (42501, P0001, 23xxx)
 * applies regardless of which dialect the catalog row
 * declares — the procedure might run on Oracle while
 * another row runs on Postgres. We key off the {@code
 * SQLState} which the JDBC driver sets; the small subset
 * that differs across vendors is handled in the
 * vendor-specific fallback (e.g. Oracle uses
 * {@code ORA-#####} which we'd need a vendor switch
 * to translate — for v1 we treat unknown states as 500
 * regardless of vendor).
 */
public final class PostgresErrorMapper {

    private static final Logger log = LoggerFactory.getLogger(PostgresErrorMapper.class);

    private PostgresErrorMapper() {}

    /**
     * Translate an SQLException (the {@code getCause()} chain
     * is walked too — driver wrappers often nest) into a
     * {@link ResponseStatusException} suitable for direct
     * throw from a controller.
     */
    public static ResponseStatusException map(SQLException ex) {
        SQLException cur = ex;
        while (cur != null) {
            ResponseStatusException mapped = mapOne(cur);
            if (mapped != null) return mapped;
            cur = cur.getNextException();
        }
        // No recognised state in the chain → fall through
        // to the default 500 with a sanitised message.
        return new ResponseStatusException(HttpStatus.INTERNAL_SERVER_ERROR,
                "Database error: " + safeMessage(ex));
    }

    /**
     * Map a single SQLException to a ResponseStatusException
     * based on its SQLState. Returns null when the state
     * doesn't match any known mapping — the caller walks
     * the {@code getNextException()} chain.
     */
    private static ResponseStatusException mapOne(SQLException ex) {
        String state = ex.getSQLState();
        if (state == null || state.length() < 2) {
            return null;
        }
        // SQLState class is the first 2 chars; subclass is
        // 3rd + 4th (some vendors leave it "00").
        String cls = state.substring(0, 2);
        switch (cls) {
            case "08": // connection_exception
                log.warn("DB connection failure (SQLState={}): {}", state, ex.getMessage());
                return new ResponseStatusException(HttpStatus.SERVICE_UNAVAILABLE,
                        "Database unreachable: " + safeMessage(ex));
            case "22": // data_exception
                log.warn("Data exception (SQLState={}): {}", state, ex.getMessage());
                return new ResponseStatusException(HttpStatus.BAD_REQUEST,
                        "Invalid input: " + safeMessage(ex));
            case "23": // integrity_constraint_violation
                log.info("Integrity violation (SQLState={}): {}", state, ex.getMessage());
                return new ResponseStatusException(HttpStatus.CONFLICT,
                        "Conflict: " + safeMessage(ex));
            case "40": // transaction_rollback (deadlock, serialization)
                log.warn("Transaction rollback (SQLState={}): {}", state, ex.getMessage());
                return new ResponseStatusException(HttpStatus.SERVICE_UNAVAILABLE,
                        "Transient DB error, retry: " + safeMessage(ex));
            case "42": // syntax_error / access_rule_violation
                // 42501 is the access-rule-violation subgroup
                // of class 42 — RAISE EXCEPTION bumps to 42501
                // when severity is set explicitly.
                if ("42501".equals(state)) {
                    log.info("Permission denied in procedure (SQLState={}): {}", state, ex.getMessage());
                    return new ResponseStatusException(HttpStatus.FORBIDDEN,
                            extractRaiseMessage(ex.getMessage()));
                }
                // Other 42xxx (syntax_error, undefined_object, …)
                // are operator mistakes — surface as 500 so the
                // alarm fires; the operator reads the message.
                log.error("SQL syntax/access error (SQLState={}): {}", state, ex.getMessage());
                return new ResponseStatusException(HttpStatus.INTERNAL_SERVER_ERROR,
                        "SQL error: " + safeMessage(ex));
            case "P0": // PL/pgSQL raise_exception
                if ("P0001".equals(state)) {
                    // RAISE EXCEPTION 'msg' — propagate the message.
                    log.info("RAISE EXCEPTION (SQLState={}): {}", state, ex.getMessage());
                    return new ResponseStatusException(HttpStatus.BAD_REQUEST,
                            extractRaiseMessage(ex.getMessage()));
                }
                if ("P0002".equals(state)) {
                    // RAISE EXCEPTION ... USING ERRCODE = 'P0002' —
                    // plpgsql's own no_data_found. The row the
                    // procedure was asked to touch doesn't exist
                    // (or isn't active); 404 fits better than the
                    // generic 400 that P0001 gets.
                    log.info("No data found (SQLState={}): {}", state, ex.getMessage());
                    return new ResponseStatusException(HttpStatus.NOT_FOUND,
                            extractRaiseMessage(ex.getMessage()));
                }
                return null;
            default:
                return null;
        }
    }

    /**
     * Pull the part after the colon in a PostgreSQL
     * {@code ERROR: prefix: detail} message. PL/pgSQL
     * RAISE EXCEPTION formats its messages as
     * {@code ERROR: <message>} or {@code ERROR: <prefix>: <detail>}.
     * We return the whole message minus the
     * {@code "ERROR: "} prefix; if there's no recognizable
     * shape, we return the raw message (operator can still
     * read it from the server logs).
     */
    static String extractRaiseMessage(String raw) {
        if (raw == null) return "Permission denied";
        // Strip a "ERROR: " prefix if present.
        String m = raw.startsWith("ERROR: ") ? raw.substring("ERROR: ".length()) : raw;
        // Cap to keep the response body small.
        return m.length() > 500 ? m.substring(0, 500) + "…" : m;
    }

    /**
     * Sanitised message for inclusion in HTTP responses.
     * Removes anything that looks like a JDBC URL
     * (jdbc:postgresql://…) and any SQL fragments longer
     * than 200 chars, to keep error bodies reasonable.
     */
    static String safeMessage(SQLException ex) {
        String m = ex.getMessage();
        if (m == null) return ex.getClass().getSimpleName();
        // Strip jdbc URLs.
        m = m.replaceAll("jdbc:[a-z]+://[^\\s]+", "<jdbc-url>");
        return m.length() > 500 ? m.substring(0, 500) + "…" : m;
    }
}
