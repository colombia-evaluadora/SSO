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