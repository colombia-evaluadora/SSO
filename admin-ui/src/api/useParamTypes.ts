import { useQuery } from "@tanstack/react-query";
import { apiClient } from "./client";

/** Response de {@code GET /sso-admin/query/param-types}. */
export interface ParamTypesResponse {
  curated: string[];
  jdbcTypes: Record<string, number>;
  /**
   * V62 — literal ({@code "!"}) que, agregado al final de un tipo de
   * {@code curated}, marca el parámetro como obligatorio (ver
   * {@code ParamTypes.parseDeclaration} en el backend). Sin el
   * sufijo, todo parámetro es nullable por defecto: null explícito
   * u omitir el campo bindean {@code NULL} de SQL en vez de tumbar
   * la petición con un 500. Se expone en vez de hardcodearlo acá
   * para que ambos lados lean la misma convención.
   */
  requiredSuffix: string;
  /**
   * V63 — literal ({@code ":"}) que separa {@code FILE} de la
   * clasificación que el autor escribe cuando declara un placeholder
   * como archivo (p. ej. {@code "FILE:perfilUsuario"}). Sólo aplica
   * cuando el tipo elegido es {@code FILE} — ver
   * {@code ParamTypes.FILE_CLASSIFICATION_SEPARATOR} en el backend.
   */
  fileClassificationSeparator: string;
  /**
   * V65 — catálogo SUGERIDO de clasificaciones (revisado contra
   * {@code TARCHIVO.etiqueta} en producción) para poblar el dropdown
   * en vez de un input de texto libre a ciegas — ver
   * {@code ParamTypes.KNOWN_FILE_CLASSIFICATIONS} en el backend. NO
   * es una lista cerrada: el backend sigue aceptando cualquier valor
   * con forma válida, así que el input permite escribir uno que no
   * esté acá.
   */
  knownFileClassifications: string[];
  /**
   * V65 — subconjunto de {@code knownFileClassifications} cuyo layout
   * histórico en S3 lleva el código de establecimiento como segmento
   * de ruta — ver
   * {@code ParamTypes.ESTABLISHMENT_SCOPED_FILE_CLASSIFICATIONS} en
   * el backend. La UI lo usa para decidir si mostrar por defecto el
   * input "campo de establecimiento" cuando el autor elige una de
   * estas clasificaciones.
   */
  establishmentScopedFileClassifications: string[];
  /**
   * V81 — subconjunto de {@code curated} que admite las reglas
   * numéricas de {@code paramConstraints} (positivo / decimales /
   * máximo de cifras). La UI la usa para decidir si el botón
   * "Restricciones" de una fila muestra las reglas numéricas.
   */
  numericTypes: string[];
  /**
   * V81 — subconjunto de {@code curated} que admite las reglas de
   * texto de {@code paramConstraints} (sólo dígitos / longitud
   * mínima / máxima).
   */
  textTypes: string[];
}

/**
 * Hook para el dropdown de tipos en el formulario de queries.
 *
 * <p>Va por {@code apiClient.get} en vez de un {@code fetch} suelto
 * para que:
 *
 * <ul>
 *   <li>el cliente le anteponga el prefijo {@code /api} (en dev el
 *       proxy de Vite lo redirige al gateway; en prod el api-gateway
 *       enruta al {@code sso-admin} interno);</li>
 *   <li>el {@code apiClient} adjunte el Bearer token del in-memory
 *       store del AuthProvider — un {@code fetch} directo no lo
 *       lleva y devuelve 401 aunque la sesión esté viva;</li>
 *   <li>el handler de 401/refresh del cliente aplique también aquí
 *       (un fetch suelto no se entera).</li>
 * </ul>
 *
 * <p>El set cambia rara vez (sólo cuando se añade un nuevo tipo PG
 * al catálogo), así que se cachea agresivamente — un redeploy del
 * backend obliga a recargar la pestaña y TanStack refetchea una vez.
 */
export function useParamTypes() {
  return useQuery<ParamTypesResponse>({
    queryKey: ["query", "param-types"],
    queryFn: () => apiClient.get<ParamTypesResponse>("/sso-admin/query/param-types"),
    staleTime: Infinity,
  });
}