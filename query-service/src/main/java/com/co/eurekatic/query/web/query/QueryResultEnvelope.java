package com.co.eurekatic.query.web.query;

import com.co.eurekatic.query.read.QueryResult;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * V31 — wire-shape adapter for read-path responses.
 *
 * <p>The legacy {@code /query}, {@code /service}, and
 * {@code /serviceFit} responses were a bare
 * {@code List<Map<String, Object>>} (just the rows). V31
 * keeps that exact wire shape for SELECT / FUNCTION
 * (backwards compatibility) and adds an envelope with
 * {@code outParams} for PROCEDURE-mode queries with
 * declared OUT params.
 *
 * <p>The path-dispatch controller
 * ({@link com.co.eurekatic.query.web.path.QueryPathController})
 * always uses the envelope shape — a single consumer
 * surface, regardless of mode.
 */
public final class QueryResultEnvelope {

    private QueryResultEnvelope() {}

    /**
     * Backwards-compatible shape: return the rows list
     * directly. Used by {@code /query} / {@code /service} so
     * legacy callers see the same JSON they always did.
     */
    public static List<Map<String, Object>> rowsOnly(QueryResult result) {
        return result.rows();
    }

    /**
     * Envelope shape: {@code { rows: [...], outParams: {...} }}.
     * Used by {@code /serviceFit} and the path-dispatch
     * controller.
     */
    public static Map<String, Object> withOutParams(QueryResult result) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("rows", result.rows());
        if (result.outParams() != null) {
            body.put("outParams", result.outParams());
        }
        return body;
    }
}
