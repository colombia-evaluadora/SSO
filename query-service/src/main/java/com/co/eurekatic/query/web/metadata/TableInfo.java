package com.co.eurekatic.query.web.metadata;

/**
 * Read-only projection of {@code DatabaseMetaData.getTables(…)}
 * for one row. {@code dialect} is always lowercased by the
 * service before mapping, so the admin UI can use it as a
 * stable filter key (the {@code SCHEMA + "." + NAME} pair can
 * rename across dialects otherwise).
 *
 * @param dialect  the {@code queryDataSources} key the row was
 *                 enumerated from ({@code postgres},
 *                 {@code oracle}, …)
 * @param schema   the {@code TABLE_SCHEM} column, may be
 *                 {@code null} for catalogs that don't track
 *                 schemas (HSQLDB embedded, etc.)
 * @param name     the {@code TABLE_NAME} column
 * @param remarks  the {@code REMARKS} column, may be
 *                 {@code null}. Not used by the admin UI but
 *                 surfaced for future "hover to see comment"
 *                 affordances.
 */
public record TableInfo(
        String dialect,
        String schema,
        String name,
        String remarks) {}
