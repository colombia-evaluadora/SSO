/**
 * Extracts the `:placeholder` names from a JDBC SQL string so
 * the admin-ui can auto-generate a parameter form. Pure
 * function — no DOM, no React.
 *
 * <p>Rules:
 * <ul>
 *   <li>Match `:name` where {@code name} starts with a letter
 *       or underscore and continues with letters, digits, or
 *       underscores (the standard JDBC named-parameter
 *       grammar).</li>
 *   <li>Deduped; insertion order preserved so the form fields
 *       render in the order the operator wrote the SQL.</li>
 *   <li>`limit` and `offset` are filtered out — those are
 *       appended automatically by query-service when the
 *       catalog SQL doesn't include its own {@code LIMIT}
 *       clause. Showing them in the UI would be confusing
 *       (the operator wrote a SQL with no {@code LIMIT} but
 *       the UI would offer one anyway).</li>
 *   <li>The {@code ::cast} Postgres-cast syntax must NOT match
 *       — handled by the negative lookbehind {@code (?<!:)}.</li>
 * </ul>
 *
 * <p>Why a negative lookbehind rather than a non-capturing
 * group: a non-capturing group would still consume one of the
 * colons, so the regex engine would still find the second one
 * (e.g. {@code '::int'}) and report it as a placeholder.
 * Lookbehind is the correct tool here.
 */

const NAMED_PARAM = /(?<!:):([A-Za-z_][A-Za-z0-9_]*)/g;
const RESERVED = new Set(["limit", "offset"]);

export function extractQueryParams(sql: string): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const m of sql.matchAll(NAMED_PARAM)) {
    const name = m[1];
    if (!name) continue;
    if (RESERVED.has(name.toLowerCase())) continue;
    if (!seen.has(name)) {
      seen.add(name);
      out.push(name);
    }
  }
  return out;
}