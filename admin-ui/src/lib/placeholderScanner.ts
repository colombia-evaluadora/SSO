/**
 * Espejo TS de {@code common/.../PlaceholderScanner.java}.
 *
 * <p>Si el regex o la semántica cambia aquí, también en Java — ver
 * el test de integración en Java que cubre los mismos casos. La
 * única diferencia intencional es que aquí no necesitamos el case
 * insensitivity porque Java ya normaliza a MAYÚSCULAS antes de
 * matching; en TS lo hacemos explícito.
 *
 * <p>V62-bis — faltaba {@code BODY_RAW} en la alternancia: el
 * regex Java lo reconoce desde V49-bis (sub-objetos JSON sin
 * aplanar), pero este espejo se quedó con los cuatro namespaces
 * originales. Efecto real: un {@code :BODY_RAW.X} en el SQL nunca
 * aparecía en la tabla "Tipos de parámetros" del formulario — el
 * autor no tenía forma de verlo ni asignarle tipo desde el
 * auto-detectado (sólo a mano, vía "Tipos manuales", si sabía que
 * tenía que hacerlo). El backend sí lo exige al guardar
 * (`QueryAdminService.validateCoverage` incluye BODY_RAW en el set
 * `required`), así que el síntoma era un 400 "PARAM_TYPES
 * incompleto" al guardar, sin que el formulario hubiera avisado
 * nada antes.
 */
const P = /:(PARAM|BODY|BODY_RAW|QUERY|CONTEXT)(\.[A-Z][A-Z0-9_]*)+/g;

export function scanPlaceholders(sql: string): string[] {
  if (!sql) return [];
  const out = new Set<string>();
  for (const m of sql.toUpperCase().matchAll(P)) {
    // strip ':' inicial
    out.add(m[0].slice(1));
  }
  return [...out];
}

/**
 * Tipos implícitos que el sistema bindea — espejo del código en
 * {@code common/.../query/ParamBinder} y {@code QueryService.injectContextParams}.
 *
 * <p>Sirve para que la UI muestre el tipo real del placeholder en
 * los selectores de los namespaces que NO controla el autor
 * ({@code CONTEXT.*} y {@code QUERY.{SIZE,OFFSET}}), en modo
 * deshabilitado: el autor no tiene que (ni puede) tiparlos, y ver
 * el valor real evita la confusión de "¿por qué este placeholder
 * aparece como 'sin tipo' en la tabla?" — el sistema se encarga.
 *
 * <p>Si el backend añade otro binding de sistema (por ejemplo
 * {@code CONTEXT.EMAIL_DOMAIN}), se actualiza este mapa Y el código
 * Java correspondiente. Los dos tienen que estar en sync.
 */
export const IMPLICIT_SYSTEM_TYPES: Record<string, string> = {
  "CONTEXT.USER_ID":     "BIGINT",
  "CONTEXT.EMAIL":       "TEXT",
  "CONTEXT.ROLES":       "TEXT",      // CSV "ADMIN,EVALUADOR"
  "CONTEXT.ROLES_ARRAY": "TEXT[]",    // "{ADMIN,EVALUADOR}"
  "QUERY.SIZE":          "INTEGER",
  "QUERY.OFFSET":        "INTEGER",
};

/** Devuelve el tipo implícito si el placeholder es de sistema, o undefined. */
export function getImplicitSystemType(placeholder: string): string | undefined {
  return IMPLICIT_SYSTEM_TYPES[placeholder];
}