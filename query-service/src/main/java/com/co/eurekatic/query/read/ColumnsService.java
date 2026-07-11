package com.co.eurekatic.query.read;

import com.co.eurekatic.query.web.metadata.ColumnInfo;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.stereotype.Service;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * Introspects a single base table on the
 * {@code queryDataSources} entry for a given dialect. Used by
 * the admin-ui Writes Catalog "pick column(s)" panel so the
 * operator doesn't have to type column names blind.
 *
 * <p><b>Security model.</b> Mirrors {@link TablesService}: we
 * only call {@link java.sql.DatabaseMetaData#getColumns} and
 * {@link java.sql.DatabaseMetaData#getPrimaryKeys}, neither of
 * which executes a SQL statement. The {@code schemaPattern} /
 * {@code tableNamePattern} arguments are forwarded straight to
 * the JDBC driver as LIKE-pattern strings — the driver itself
 * builds a {@code WHERE} against the catalog table; no
 * concatenation ever reaches a {@code Statement.execute} call.
 * Even a hostile pattern like {@code %; DROP TABLE foo}
 * cannot inject because no {@code DROP} is ever issued.
 *
 * <p>That said, a permissive schema / table pattern (e.g.
 * just {@code "%"}) can return a large result on a busy DB.
 * We therefore restrict {@code schema} and {@code table} on
 * the wire to an identifier charset so a misconfigured caller
 * can't accidentally fan-out a thousand rows. The catalog
 * itself never runs user SQL, so this is purely a
 * UX / load-guard.
 *
 * <p><b>Dialect resolution.</b> The dialect key comes off the
 * query string verbatim (case-folded to lowercase) and is
 * looked up against the {@code queryDataSources} bean built
 * by {@code DataSourceConfig}. A miss throws
 * {@link IllegalArgumentException} so the project's
 * {@code GlobalExceptionHandler} can return 400 BAD_REQUEST
 * with the standard JSON envelope — the caller can render a
 * friendly toast without parsing a 500.
 */
@Service
public class ColumnsService {

    private static final Logger log = LoggerFactory.getLogger(ColumnsService.class);

    /**
     * Identifier charset for the {@code schema} and
     * {@code table} filters. Tightens LIKE-pattern
     * meta-characters ({@code %} and {@code _}) so a caller
     * can't ask for "everything". Empty / null is invalid for
     * both — this endpoint requires a target table.
     */
    private static final Pattern IDENTIFIER = Pattern.compile("[a-zA-Z0-9_]+");

    private final Map<String, DataSource> sources;

    public ColumnsService(@Qualifier("queryDataSources") Map<String, DataSource> sources) {
        this.sources = sources;
    }

    /**
     * Lists base columns ({@code new String[]{"TABLE"}} as
     * the catalog pattern is unused; {@code getColumns} takes
     * per-table) for the given dialect's binding of a single
     * table, plus a {@code primaryKey} flag per row.
     *
     * @param dialect        the {@code queryDataSources} key
     *                       ({@code postgres}, {@code oracle},
     *                       {@code sqlserver}).
     *                       Case-insensitive.
     * @param schemaPattern  schema of the target table — must
     *                       match {@code [a-zA-Z0-9_]+}. Use
     *                       {@code null} / empty for catalogs
     *                       that don't track schemas.
     * @param table          table name — must match
     *                       {@code [a-zA-Z0-9_]+}.
     * @return row per column, in the order returned by the
     *         JDBC driver (typically ordinal position)
     * @throws IllegalArgumentException for unknown dialects,
     *         missing {@code schema}/{@code table}, or
     *         malformed identifiers — all map to 400 via
     *         {@code GlobalExceptionHandler}.
     */
    public List<ColumnInfo> list(String dialect, String schemaPattern, String table) {
        if (dialect == null || dialect.isBlank()) {
            throw new IllegalArgumentException("dialect is required");
        }
        if (table == null || table.isBlank()) {
            throw new IllegalArgumentException("table is required");
        }
        String key = dialect.toLowerCase(Locale.ROOT);
        DataSource ds = sources.get(key);
        if (ds == null) {
            throw new IllegalArgumentException(
                    "dialect '" + key + "' is not provisioned in this instance");
        }

        String sp = (schemaPattern == null || schemaPattern.isBlank())
                ? null : schemaPattern;
        if (sp != null && !IDENTIFIER.matcher(sp).matches()) {
            throw new IllegalArgumentException(
                    "schema must match [a-zA-Z0-9_]+ (no LIKE meta-chars)");
        }
        if (!IDENTIFIER.matcher(table).matches()) {
            throw new IllegalArgumentException(
                    "table must match [a-zA-Z0-9_]+ (no LIKE meta-chars)");
        }

        try (Connection conn = ds.getConnection()) {
            Set<String> pkColumns = primaryKeySet(conn, sp, table);

            ResultSet rs = conn.getMetaData().getColumns(
                    null, sp, table, null);
            List<ColumnInfo> out = new ArrayList<>();
            while (rs.next()) {
                String colName = rs.getString("COLUMN_NAME");
                out.add(new ColumnInfo(
                        key,
                        rs.getString("TABLE_SCHEM"),
                        rs.getString("TABLE_NAME"),
                        colName,
                        rs.getString("TYPE_NAME"),
                        normalizeNullable(rs.getString("IS_NULLABLE")),
                        pkColumns.contains(colName)));
            }
            log.debug("columns list — dialect={} schema={} table={} returned {} rows ({} PKs)",
                    key, sp, table, out.size(), pkColumns.size());
            return out;
        } catch (SQLException e) {
            // Wrap so the GlobalExceptionHandler catch-all
            // surfaces a 500 with the standard envelope.
            // SQLException itself has no status mapping.
            throw new IllegalStateException(
                    "Failed to enumerate columns for dialect " + key
                            + " table " + sp + "." + table, e);
        }
    }

    /**
     * One round-trip to {@code getPrimaryKeys}; returns the
     * set of column names that are part of any PK. Empty set
     * if the table has no PK. Composite keys fold into the
     * set naturally because we OR per-key-seq entries.
     *
     * <p>If the JDBC driver throws on the PK call (some
     * lightweight ones do) we degrade gracefully to an empty
     * set — columns are still returned, just without the
     * {@code primaryKey} flag set. Better than 500-ing the
     * whole request because of a metadata side-channel.
     */
    private Set<String> primaryKeySet(Connection conn, String schemaPattern, String table) {
        Set<String> pks = new HashSet<>();
        try {
            ResultSet rs = conn.getMetaData().getPrimaryKeys(
                    null, schemaPattern, table);
            while (rs.next()) {
                String col = rs.getString("COLUMN_NAME");
                if (col != null) {
                    pks.add(col);
                }
            }
        } catch (SQLException e) {
            log.warn("getPrimaryKeys failed for {}.{} — degrading to no PK flag",
                    schemaPattern, table, e);
        }
        return pks;
    }

    /**
     * Normalize the various {@code IS_NULLABLE} representations
     * the JDBC ecosystem has produced over the years:
     * <ul>
     *   <li>{@code "YES"} / {@code "NO"} — JDBC spec</li>
     *   <li>{@code "true"} / {@code "false"} — some drivers</li>
     *   <li>{@code ""} / {@code null} — unknown / not provided</li>
     * </ul>
     * Anything that isn't an explicit affirmative maps to
     * {@code true} (the JDBC spec is permissive — unknown
     * means "we don't promise"). The admin UI uses this as a
     * hint chip, not a hard validator.
     */
    private boolean normalizeNullable(String raw) {
        if (raw == null) return true;
        String v = raw.trim();
        if (v.isEmpty()) return true;
        return !v.equalsIgnoreCase("NO") && !v.equalsIgnoreCase("false");
    }
}
