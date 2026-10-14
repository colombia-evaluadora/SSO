package com.co.eurekatic.aicontrol.agente.catalogo.turno;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Filas de permisos a {@link AccesoMenu}. Pura.
 *
 * <p>Solo cuentan los menus que el usuario ve. Un menu es de solo lectura si no puede crear
 * ni editar dentro de el; eliminar no cambia la clasificacion porque el agente no borra.
 */
public final class MapeadorMenus {

    private MapeadorMenus() {
    }

    public static Map<String, AccesoMenu> desde(List<FilaMenu> filas) {
        Map<String, AccesoMenu> menus = new LinkedHashMap<>();
        for (FilaMenu fila : filas) {
            if (!fila.puedeVer() || fila.codigo() == null || fila.codigo().isBlank()) {
                continue;
            }
            boolean soloLectura = !(fila.puedeCrear() || fila.puedeEditar());
            menus.put(fila.codigo().trim(), new AccesoMenu(soloLectura));
        }
        return Map.copyOf(menus);
    }
}
