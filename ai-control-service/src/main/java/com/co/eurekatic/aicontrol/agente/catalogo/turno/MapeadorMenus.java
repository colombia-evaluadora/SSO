package com.co.eurekatic.aicontrol.agente.catalogo.turno;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Filas de la ruta de menus a {@link AccesoMenu}. Pura.
 *
 * <p>Columnas esperadas de {@code academico_test.fn_usuario_permisos_menu}: {@code codigo},
 * {@code puede_ver}, {@code puede_crear}, {@code puede_editar}, {@code puede_eliminar}. Un menu
 * sin codigo no se puede cruzar con las herramientas y se omite.
 */
public final class MapeadorMenus {

    private MapeadorMenus() {
    }

    public static Map<String, AccesoMenu> desde(List<Map<String, Object>> filas) {
        Map<String, AccesoMenu> menus = new LinkedHashMap<>();
        for (Map<String, Object> fila : filas) {
            String codigo = fila.get("codigo") instanceof String texto && !texto.isBlank() ? texto.trim() : null;
            if (codigo == null || !esTrue(fila.get("puede_ver"))) {
                continue;
            }
            boolean puedeModificar = esTrue(fila.get("puede_crear"))
                    || esTrue(fila.get("puede_editar"))
                    || esTrue(fila.get("puede_eliminar"));
            menus.put(codigo, new AccesoMenu(!puedeModificar));
        }
        return Map.copyOf(menus);
    }

    private static boolean esTrue(Object valor) {
        return Boolean.TRUE.equals(valor);
    }
}
