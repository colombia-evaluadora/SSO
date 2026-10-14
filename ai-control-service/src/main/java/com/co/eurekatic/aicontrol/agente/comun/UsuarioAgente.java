package com.co.eurekatic.aicontrol.agente.comun;

import java.util.Objects;
import java.util.Set;

/**
 * Quien pide el turno: id de usuario, roles del JWT y el token con el que se llama al query-service.
 * El token nunca sale en {@link #toString()}.
 *
 * @param userId id de {@code public.users}
 * @param roles  roles del JWT
 * @param bearer token del usuario, sin el prefijo "Bearer "
 */
public record UsuarioAgente(long userId, Set<String> roles, String bearer) {

    public UsuarioAgente {
        Objects.requireNonNull(roles, "roles");
        Objects.requireNonNull(bearer, "bearer");
        roles = Set.copyOf(roles);
    }

    @Override
    public String toString() {
        return "UsuarioAgente[userId=" + userId + "]";
    }
}
