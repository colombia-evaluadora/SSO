package com.co.eurekatic.query.read;

import java.util.List;
import java.util.Map;

/**
 * Envelope for the read-path response.
 *
 * <p>Always carries {@code rows} — a flat list of column →
 * value maps the consumer renders as a table — plus an
 * optional {@code outParams} map for PROCEDURE-mode queries
 * that declare OUT params via {@code outParamNames}: each
 * declared placeholder is registered with the JDBC driver
 * via {@code CallableStatement.registerOutParameter} and the
 * runtime value is exposed here under the same name
 * (without the leading {@code :}).
 *
 * <p>For SELECT-mode and OUT-less procedure calls,
 * {@code outParams} is {@code null} — the controller strips
 * it from the JSON response so {@code /query} clients keep the
 * bare {@code [row, row, …]} shape.
 */
public record QueryResult(List<Map<String, Object>> rows,
                          Map<String, Object> outParams) {

    public static QueryResult rowsOnly(List<Map<String, Object>> rows) {
        return new QueryResult(rows, null);
    }

    public static QueryResult withOutParams(List<Map<String, Object>> rows,
                                            Map<String, Object> outParams) {
        return new QueryResult(rows,
                outParams == null || outParams.isEmpty() ? null : outParams);
    }
}
