package com.co.eurekatic.aicontrol.agente.catalogo.turno;

/**
 * Fila de {@code ai.fn_menus_usuario_interno(:uid)}: los permisos del usuario sobre un menu.
 *
 * @param codigo        codigo del menu en {@code academico_test.tmenu}
 * @param puedeVer      si el usuario ve el menu
 * @param puedeCrear    si puede crear dentro del menu
 * @param puedeEditar   si puede editar dentro del menu
 * @param puedeEliminar si puede eliminar dentro del menu
 */
public record FilaMenu(String codigo, boolean puedeVer, boolean puedeCrear, boolean puedeEditar,
                       boolean puedeEliminar) {
}
