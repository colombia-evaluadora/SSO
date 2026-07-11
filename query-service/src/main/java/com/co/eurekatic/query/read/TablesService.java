package com.co.eurekatic.query.read;

import com.co.eurekatic.query.web.metadata.TableInfo;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.stereotype.Service;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Pattern;

/**
 * Introspects the {@link DataSource} for a given dialect and
 * returns the list of base tables. Used by the admin-ui
 * Writes Catalog picker so the operator doesn't have to type
 * {@code public.foo} blind.
 *
 * <p><b>Security model.</b> We only call
 * {@link java.sql.DatabaseMetaData#getTables}, which NEVER
 * executes a SQL statement. The {@code schemaPattern}
 * argument is forwarded straight to the JDBC driver as a
 * LIKE-pattern string — the driver itself builds a
 * {@code WHERE} against the system's catalog table; no
 * concatenation reaches a {@code Statement.execute} call.
 * Even a hostile schema like {@code %; DROP TABLE foo}
 * cannot inject because no {@code DROP} is ever issued.
 *
 * <p>That said, a permissive schema pattern (e.g. just
 * {@code "%"}) can return a large result on a busy DB. We
 * therefore restrict {@code schema} on the wire to an
 * identifier charset so a misconfigured caller can't
 * accidentally fan-out a thousand rows. The catalog itself
 * never runs user SQL, so this is purely a UX / load-guard.
 *
 * <p><b>Dialect resolution.</b> The dialect key comes off the
 * query string verbatim (case-folded to lowercase) and is
 * looked up against the {@code queryDataSources} bean
 * built by {@code DataSourceConfig}. A miss throws
 * {@link IllegalArgumentException} so the project's
 * {@code GlobalExceptionHandler} can return 400 BAD_REQUEST
 * with the standard JSON envelope — the caller can render a
 * friendly toast without parsing a 500.
 */
@Service
public class TablesService {

    private static final Logger log = LoggerFactory.getLogger(TablesService.class);

    /**
     * Identifier charset for the {@code schema} filter.
     * Tightens LIKE-pattern meta-characters ({@code %} and
     * {@code _}) so a caller can't ask for "everything".
     * Empty / null means "no schema filter" (uses the
     * connection's default catalog).
     */
    private static final Pattern SCHEMA_PATTERN = Pattern.compile("[a-zA-Z0-9_]*");

    private final Map<String, DataSource> sources;

    public TablesService(@Qualifier("queryDataSources") Map<String, DataSource> sources) {
        this.sources = sources;
    }

    /**
     * Lists base tables ({@code new String[]{"TABLE"}}) for
     * the given dialect, optionally narrowed to a single
     * schema.
     *
     * @param dialect        the {@code queryDataSources} key
     *                       ({@code postgres}, {@code oracle},
     *                       {@code sqlserver}). Case-insensitive.
     * @param schemaPattern  optional, an identifier (no LIKE
     *                       meta-chars). {@code null}/empty
     *                       means "all schemas".
     * @return row per base table, in the order returned by
     *         the JDBC driver
     * @throws IllegalArgumentException for unknown dialects or
     *         malformed {@code schema} — both map to 400 via
     *         {@code GlobalExceptionHandler}.
     */
    public List<TableInfo> list(String dialect, String schemaPattern) {
        if (dialect == null || dialect.isBlank()) {
            throw new IllegalArgumentException("dialect is required");
        }
        String key = dialect.toLowerCase(Locale.ROOT);
        DataSource ds = sources.get(key);
        if (ds == null) {
            throw new IllegalArgumentException(
                    "dialect '" + key + "' is not provisioned in this instance");
        }
        String sp = (schemaPattern == null || schemaPattern.isBlank())
                ? null
                : schemaPattern;
        if (sp != null && !SCHEMA_PATTERN.matcher(sp).matches()) {
            throw new IllegalArgumentException(
                    "schema must match [a-zA-Z0-9_]+ (no LIKE meta-chars)");
        }

        try (Connection conn = ds.getConnection()) {
            ResultSet rs = conn.getMetaData().getTables(
                    null, sp, null, new String[]{"TABLE"});
            List<TableInfo> out = new ArrayList<>();
            while (rs.next()) {
                out.add(new TableInfo(
                        key,
                        rs.getString("TABLE_SCHEM"),
                        rs.getString("TABLE_NAME"),
                        rs.getString("REMARKS")));
            }
            log.debug("tables list — dialect={} schema={} returned {} rows",
                    key, sp, out.size());
            return out;
        } catch (SQLException e) {
            // Wrap so the GlobalExceptionHandler catch-all
            // surfaces a 500 with the standard envelope.
            // SQLException itself has no status mapping.
            throw new IllegalStateException(
                    "Failed to enumerate tables for dialect " + key, e);
        }
    }
}
