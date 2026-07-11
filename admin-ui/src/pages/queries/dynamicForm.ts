/**
 * Utilidades para construir un formulario "automático" sobre el
 * SQL de una query del catálogo. La idea es: el admin escribe una
 * sola vez el SQL con `:placeholder` por cada parámetro, y la SPA
 * renderiza un input por cada placeholder — sin saber nada de la
 * tabla ni de las columnas.
 *
 * Decisiones:
 * <ul>
 *   <li>{@link extractPlaceholders} hace regex perezoso
 *       (NO parsea SQL). Solo acepta `[a-zA-Z_][a-zA-Z0-9_]*`,
 *       igual que {@code NamedParameterJdbcTemplate} al resolver
 *       los bindings.</li>
 *   <li>{@link parseQueryDetail} intenta parsear el `detail`
 *       como JSON; si falla, devuelve `{}` silenciosamente.
 *       Mantiene compatibilidad hacia atrás con queries que ya
 *       tienen `detail` como texto libre.</li>
 *   <li>Los tipos no se infieren del SQL — se declaran en
 *       {@code detail.fieldTypes}. Esto es consciente: inferir
 *       tipos del SQL sería parsear SQL, lo cual es una
 *       pendiente técnica que no queremos meter.</li>
 * </ul>
 *
 * Los tipos definidos aquí son compartidos por el parser, el
 * form dinámico y (en el futuro) el workflow runner.
 */

export type FieldType = "text" | "number" | "email" | "date" | "boolean";

export interface FieldValidation {
  required?: boolean;
  format?: "email" | "uuid" | "url";
  minLength?: number;
  maxLength?: number;
  pattern?: string;
}

export interface WorkflowStep {
  uuid: string;
  abortOn?: "rows_gt_0" | "empty" | "error";
  isResult?: boolean;
}

export interface QueryMetadata {
  targetTable?: string;
  targetAction?: string;
  fieldTypes?: Record<string, FieldType>;
  validate?: Record<string, FieldValidation>;
  workflow?: WorkflowStep[];
}

/**
 * Extrae la lista única de placeholders `:foo` en orden de
 * aparición. No parsea SQL — regex perezosa sobre el texto
 * crudo. Ignora repeticiones (la misma `:foo` no se renderiza
 * dos veces), porque un input con el mismo nombre dos veces
 * no aporta UI útil y duplica el valor al ejecutar.
 */
export function extractPlaceholders(sql: string): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  const re = /:([a-zA-Z_][a-zA-Z0-9_]*)/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(sql)) !== null) {
    const name = m[1];
    if (name == null) continue;
    if (!seen.has(name)) {
      seen.add(name);
      out.push(name);
    }
  }
  return out;
}

/**
 * Parsea el `detail` (texto libre) a metadata estructurada.
 * Devuelve `{}` si `detail` es null/vacío/no-JSON.
 *
 * Forma esperada:
 * <pre>{@code
 * {
 *   "targetTable":  "users",
 *   "targetAction": "SELECT" | "INSERT" | "UPDATE" | "DELETE",
 *   "fieldTypes":   { "email": "email", "monto": "number" },
 *   "validate":     { "email": { "required": true, "format": "email" } },
 *   "workflow":     [ { "uuid": "users.check-id", "abortOn": "rows_gt_0" } ]
 * }
 * }</pre>
 */
export function parseQueryDetail(detail: string | null | undefined): QueryMetadata {
  if (!detail) return {};
  try {
    return JSON.parse(detail) as QueryMetadata;
  } catch {
    return {};
  }
}

/**
 * Resuelve la "tabla" lógica para agrupar queries en el picker.
 * Prioriza {@code metadata.targetTable} (lo que el admin
 * declara), y como fallback usa el prefijo del uuid antes
 * del primer `.` (convención "tabla.accion").
 *
 * Ejemplos:
 *   uuid="users.list"             → "users"
 *   uuid="personas.find-by-id"    → "personas"  (convención)
 *   uuid="users.list" con
 *     targetTable="personas"      → "personas"   (admin override)
 *   uuid="sin_prefijo"            → "Otras"
 */
export function resolveQueryTable(
  uuid: string,
  meta: QueryMetadata,
): string {
  if (meta.targetTable) return meta.targetTable;
  const idx = uuid.indexOf(".");
  if (idx > 0) return uuid.slice(0, idx);
  return "Otras";
}
