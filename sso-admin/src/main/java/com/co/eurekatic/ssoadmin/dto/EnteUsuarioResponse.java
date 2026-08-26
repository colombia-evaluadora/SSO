package com.co.eurekatic.ssoadmin.dto;

import java.util.List;

/**
 * V-ente-admin — confirma el bind/unbind y muestra el set COMPLETO de
 * roles CEVAL- y PIGSE- que el usuario tiene después de la operación
 * (no sólo el que se acaba de tocar): {@code fn_sincronizar_rol_publico}
 * es un full-resync, así que la forma más honesta de reportar el
 * resultado es mostrar el estado final, no inferir un delta.
 */
public record EnteUsuarioResponse(boolean ok, List<String> rolesActuales) {}
