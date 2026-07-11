package com.co.eurekatic.query.web.metadata;

/**
 * Read-only projection of {@code DatabaseMetaData.getColumns(…)}
 * joined with {@code DatabaseMetaData.getPrimaryKeys(…)} for one
 * row. Used by the admin-ui Writes Catalog "pick a column(s)"
 * panel so the operator doesn't have to type column names blind.
 *
 * <p>The frontend wants the {@code primaryKey} boolean inlined
 * per row so it can render a "(PK)" badge and pre-tick the
 * {@code keyColumns} picker for {@code UPDATE} writes. We
 * resolve PKs separately because {@code getColumns} doesn't
 * surface that bit — joining on the JDBC side keeps the
 * admin-ui types compact (one list, no nested lookup).
 *
 * @param dialect     the {@code queryDataSources} key the row
 *                    was enumerated from. Always lowercased
 *                    by the service before mapping, so the
 *                    admin UI can use it as a stable filter
 *                    key.
 * @param schema      the {@code TABLE_SCHEM} of the parent
 *                    table, may be {@code null} for catalogs
 *                    without schemas.
 * @param table       the {@code TABLE_NAME} of the parent
 *                    table. Echoed back so the frontend can
 *                    disambiguate when two tables from
 *                    different schemas share a column name
 *                    (e.g. {@code audit.created_at} vs
 *                    {@code public.created_at}).
 * @param name        the {@code COLUMN_NAME} — the actual
 *                    value the admin types into the write
 *                    definition.
 * @param dataType    the {@code TYPE_NAME} from the JDBC driver
 *                    ({@code varchar}, {@code integer},
 *                    {@code timestamp}, …). Surface only; the
 *                    frontend renders it as a small chip.
 * @param nullable    {@code IS_NULLABLE} from {@code YES/NO}.
 *                    Some drivers return {@code "YES" /
 *                    "NO"}, others an empty string or
 *                    {@code "true"/"false"} — we normalize to a
 *                    strict boolean in the service.
 * @param primaryKey  {@code true} when this column is part of
 *                    the parent table's primary key per
 *                    {@code DatabaseMetaData.getPrimaryKeys}.
 *                    One column can have more than one PK
 *                    entry on a composite key — we OR them
 *                    together here. The admin UI uses this
 *                    bit to pre-tick the {@code keyColumns}
 *                    picker on {@code UPDATE} writes.
 */
public record ColumnInfo(
        String dialect,
        String schema,
        String table,
        String name,
        String dataType,
        boolean nullable,
        boolean primaryKey) {}
