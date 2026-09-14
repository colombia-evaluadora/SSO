package com.co.eurekatic.query.web.query;

import com.co.eurekatic.query.read.QueryResult;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Wire-shape adapter for read-path responses.
 *
 * <p>{@code /query} and {@code /service} answer a bare
 * {@code List<Map<String, Object>>} (just the rows);
 * {@code /serviceFit} and the path dispatcher answer an envelope
 * that also carries {@code outParams} for PROCEDURE-mode queries
 * with declared OUT params.
 *
 * <p>The path-dispatch controller
 * ({@link com.co.eurekatic.query.web.path.QueryPathController})
 * always uses the envelope shape — a single consumer
 * surface, regardless of mode.
 */
public final class QueryResultEnvelope {

    private QueryResultEnvelope() {}

    /**
     * Bare shape: the rows list directly. Used by {@code /query} /
     * {@code /service}.
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
