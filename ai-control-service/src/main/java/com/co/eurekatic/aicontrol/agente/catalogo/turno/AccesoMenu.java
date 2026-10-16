package com.co.eurekatic.aicontrol.agente.catalogo.turno;

/**
 * Acceso del usuario a un menu.
 *
 * @param soloLectura true si el usuario ve el menu pero no puede crear, editar ni eliminar
 */
public record AccesoMenu(boolean soloLectura) {
}
