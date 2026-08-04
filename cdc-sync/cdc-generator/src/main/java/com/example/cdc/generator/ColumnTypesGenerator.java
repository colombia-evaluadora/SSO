package com.example.cdc.generator;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Regenerates cdc-common/src/main/resources/column-types.json from the
 * V22 idempotent migration (postgres/migrations/V22__academic-schema.sql).
 *
 * <p>Direct port of the Python script
 * {@code db-migrations/cdc-sync/scripts/generate-column-types.py}, with
 * three V22-specific fixes baked in:
 *
 * <ol>
 *   <li>CREATE TABLE regex tolerates {@code IF NOT EXISTS} (every V22
 *       header is {@code CREATE TABLE IF NOT EXISTS NAME (}, which would
 *       make the original Python regex capture {@code IF} as the table
 *       name).</li>
 *   <li>CREATE DOMAIN regex still matches inside {@code DO $$ ... $$;}
 *       PL/pgSQL wrappers because the search is whitespace-tolerant.</li>
 *   <li>Column-line detection uses a deny-list + type-allowlist rather
 *       than a prefix skip. This auto-rejects multiline CHECK
 *       continuations like {@code (URL IS NOT NULL AND ...)} which the
 *       Python script's line-prefix logic misses.</li>
 * </ol>
 *
 * <p>Slot rules (1..11) are copied verbatim from the Python script —
 * no behavior change for any column. The output shape matches the
 * committed {@code column-types.json} exactly so the runtime
 * {@code ColumnTypeRegistry.loadFromClasspath(...)} consumer keeps
 * working unchanged.
 */
public final class ColumnTypesGenerator {

    private static final ObjectMapper MAPPER =
            new ObjectMapper().enable(SerializationFeature.INDENT_OUTPUT);

    // Capture CREATE DOMAIN name (works inside DO $$ ... $$; wrappers).
    private static final Pattern DOMAIN_PATTERN =
            Pattern.compile("CREATE\\s+DOMAIN\\s+(\\w+)\\s+AS",
                    Pattern.CASE_INSENSITIVE);

    // Capture (table_name, body). The IF NOT EXISTS group is optional so
    // both V22's `CREATE TABLE IF NOT EXISTS X (` and the original
    // `CREATE TABLE X (` match. DOTALL lets `.` span newlines so the body
    // is captured verbatim; the lazy `*?` stops at the first `;`.
    private static final Pattern TABLE_PATTERN =
            Pattern.compile(
                    "CREATE\\s+TABLE\\s+(?:IF\\s+NOT\\s+EXISTS\\s+)?(\\w+)\\s*\\((.*?)\\);",
                    Pattern.CASE_INSENSITIVE | Pattern.DOTALL);

    // Lines beginning with these tokens are constraint / key declarations,
    // never column declarations. PRIMARY KEY / FOREIGN KEY / UNIQUE / CHECK
    // catch the bare forms seen in TLISTA_VALOR's mid-body; CONSTRAINT
    // catches every named PK / FK / UNIQUE / CHECK (the only FK shape
    // present in V22 — 413 occurrences).
    private static final Set<String> DENY_FIRST_TOKENS = Set.of(
            "PRIMARY", "FOREIGN", "UNIQUE", "CHECK", "CONSTRAINT");

    // Plain PG types a column declaration's second token may equal.
    // Parameterized forms (VARCHAR(30), NUMERIC(4), ...) are matched by
    // TYPE_PARAM_PATTERN below. TIME / INTERVAL / TIMETZ cover the
    // academico_test schema's hour fields (e.g. TDESCANSOS.HORA_INICIO);
    // the rest is forward-looking coverage for future schema additions.
    private static final Set<String> KNOWN_PLAIN_TYPES = Set.of(
            "VARCHAR", "CHAR", "TEXT", "BIGINT", "INTEGER", "SMALLINT",
            "NUMERIC", "DECIMAL", "BOOLEAN", "DATE", "TIMESTAMP",
            "TIMESTAMPTZ", "TIME", "TIMETZ", "INTERVAL", "BYTEA", "REAL",
            "DOUBLE", "PRECISION", "UUID", "JSONB", "JSON", "XML",
            "MONEY", "INET", "CIDR", "MACADDR", "MACADDR8");

    private static final Pattern TYPE_PARAM_PATTERN =
            Pattern.compile("^[A-Z][A-Z0-9_]*\\(\\d+(?:\\s*,\\s*\\d+)?\\)$");

    private ColumnTypesGenerator() {}

    public static void main(String[] args) throws IOException {
        Map<String, String> opts = parseArgs(args);
        Path source = Path.of(opts.get("--source"));
        Path out = Path.of(opts.get("--out"));

        if (!Files.isRegularFile(source)) {
            throw new IllegalArgumentException("Source not found: " + source);
        }

        String sql = Files.readString(source);
        Set<String> domains = parseDomains(sql);
        Map<String, Object> root = buildColumnTypesJson(sql, source, domains);

        Path parent = out.getParent();
        if (parent != null) {
            Files.createDirectories(parent);
        }
        MAPPER.writerWithDefaultPrettyPrinter()
                .with(SerializationFeature.INDENT_OUTPUT)
                .writeValue(out.toFile(), root);

        int nTables = ((Map<?, ?>) root.get("tables")).size();
        int nCols = ((Map<?, ?>) root.get("tables")).values().stream()
                .mapToInt(t -> ((Map<?, ?>) ((Map<?, ?>) t).get("columns")).size())
                .sum();
        System.out.printf("Wrote %s — %d tables, %d columns%n",
                out, nTables, nCols);
    }

    /** Parses CLI flags. Recognized flags: {@code --source}, {@code --out}. */
    static Map<String, String> parseArgs(String[] args) {
        Map<String, String> out = new LinkedHashMap<>();
        // Defaults are anchored at /workspace which is the WORKDIR used
        // by the cdc-worker Dockerfile build stage. They are also
        // sensible when the generator is invoked from cdc-sync/ during a
        // local `mvn exec:java` style run (../postgres, ../cdc-common).
        Path cwd = Path.of("").toAbsolutePath();
        out.put("--source", cwd.resolve("../postgres/migrations/V22__academic-schema.sql")
                .normalize().toString());
        out.put("--out", cwd.resolve("../cdc-common/src/main/resources/column-types.json")
                .normalize().toString());
        for (int i = 0; i < args.length - 1; i++) {
            if (args[i].startsWith("--")) {
                out.put(args[i], args[i + 1]);
                i++;
            }
        }
        return out;
    }

    /** Lowercased set of CREATE DOMAIN names declared anywhere in {@code sql}. */
    static Set<String> parseDomains(String sql) {
        Set<String> domains = new java.util.HashSet<>();
        Matcher m = DOMAIN_PATTERN.matcher(sql);
        while (m.find()) {
            domains.add(m.group(1).toLowerCase(Locale.ROOT));
        }
        return domains;
    }

    /** Returns the column-types JSON root (version + tables map). */
    static Map<String, Object> buildColumnTypesJson(
            String sql, Path source, Set<String> domainsLower) {
        Set<String> domainsUpper = new java.util.HashSet<>();
        for (String d : domainsLower) domainsUpper.add(d.toUpperCase(Locale.ROOT));

        Map<String, Object> tables = new LinkedHashMap<>();
        Matcher m = TABLE_PATTERN.matcher(sql);
        while (m.find()) {
            String tableName = m.group(1);
            String body = m.group(2);
            Map<String, Object> table = new LinkedHashMap<>();
            table.put("schema", "academico_test");
            table.put("columns", parseColumns(body, domainsUpper));
            tables.put(tableName.toLowerCase(Locale.ROOT), table);
        }

        Map<String, Object> root = new LinkedHashMap<>();
        root.put("version", String.valueOf(source.toFile().lastModified() / 1000L));
        root.put("tables", tables);
        return root;
    }

    /**
     * Parses one CREATE TABLE body into a per-column map. A line is a
     * column declaration only if its first token isn't in the deny-list
     * AND its second token looks like a PG type or domain name. This is
     * what makes the parser robust against multiline CHECK / constraint
     * continuations.
     */
    static Map<String, Object> parseColumns(String body, Set<String> domainsUpper) {
        Map<String, Object> cols = new LinkedHashMap<>();
        for (String raw : body.split("\\R")) {
            String line = raw.strip().replaceAll(",\\s*$", "");
            if (line.isEmpty()) continue;

            String[] tokens = line.split("\\s+");
            if (tokens.length < 2) continue;

            String firstTokenUpper = tokens[0].toUpperCase(Locale.ROOT);
            if (DENY_FIRST_TOKENS.contains(firstTokenUpper)) continue;

            String colName = tokens[0];
            if (!colName.matches("[A-Za-z_][A-Za-z0-9_]*")) continue;

            String normalizedType = normalizeType(tokens[1]);
            if (!isTypeToken(normalizedType, domainsUpper)) continue;

            String colLower = colName.toLowerCase(Locale.ROOT);
            String slot = slotForColumn(
                    colLower,
                    normalizedType.toUpperCase(Locale.ROOT),
                    domainsUpper);
            cols.put(colLower, Map.of(
                    "pg_type", normalizedType,
                    "slot", slot));
        }
        return cols;
    }

    /**
     * Normalizes {@code VARCHAR(N CHAR|BYTE)} to {@code VARCHAR(N)}.
     * Dead code for V22 (all 578 VARCHARs are already plain) but kept
     * for parity with the Python script.
     */
    static String normalizeType(String raw) {
        String upper = raw.toUpperCase(Locale.ROOT);
        if (upper.startsWith("VARCHAR") && upper.contains("(")) {
            int open = upper.indexOf('(');
            int close = upper.indexOf(')');
            if (close > open) {
                String inside = upper.substring(open + 1, close).split("\\s+")[0];
                return "VARCHAR(" + inside + ")";
            }
        }
        return upper;
    }

    /**
     * Returns true if {@code normalized} is a plain PG type, a
     * parameterized form (VARCHAR(30), NUMERIC(10,2), ...), or a domain
     * declared in the source SQL.
     */
    static boolean isTypeToken(String normalized, Set<String> domainsUpper) {
        if (KNOWN_PLAIN_TYPES.contains(normalized)) return true;
        if (TYPE_PARAM_PATTERN.matcher(normalized).matches()) return true;
        return domainsUpper.contains(normalized);
    }

    /**
     * First matching rule wins. Rule 11 always matches so this never
     * returns null. The eleven rules are copied verbatim from
     * db-migrations/cdc-sync/scripts/generate-column-types.py — order
     * matters because rule 3 catches {@code *_fecha} before rule 4
     * could see {@code *_at}.
     */
    static String slotForColumn(String colLower, String typeUpper, Set<String> domainsUpper) {
        if (colLower.startsWith("pk_")) return "pk_t";
        if (colLower.startsWith("fk_")) return "padre_id_json";
        if (typeUpper.equals("DATE") || colLower.endsWith("_fecha")) return "fecha";
        if (typeUpper.equals("TIMESTAMP") || typeUpper.equals("TIMESTAMPTZ")
                || colLower.endsWith("_at")) return "fecha_ts";
        if ((domainsUpper.contains("BOOL_SN") && typeUpper.startsWith("VARCHAR(1)"))
                || colLower.endsWith("_sn")) return "booleano_sn";
        if (typeUpper.startsWith("NUMERIC") || typeUpper.startsWith("DECIMAL"))
            return "decimal";
        if (typeUpper.equals("BIGINT") || typeUpper.equals("INTEGER")
                || typeUpper.equals("SMALLINT")) return "numero";
        if (colLower.equals("codigo") || colLower.startsWith("codigo_")
                || colLower.endsWith("_codigo")) return "codigo";
        if (colLower.equals("nombre") || colLower.startsWith("nombre_")
                || colLower.endsWith("_nombre")) return "nombre";
        if (colLower.equals("valor") || colLower.startsWith("valor_")
                || colLower.endsWith("_valor")) return "valor";
        return "texto";
    }
}