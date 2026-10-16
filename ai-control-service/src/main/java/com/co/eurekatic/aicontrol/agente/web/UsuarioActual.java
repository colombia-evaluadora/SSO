package com.co.eurekatic.aicontrol.agente.web;

import com.co.eurekatic.aicontrol.agente.comun.ErrorAgente;
import com.co.eurekatic.aicontrol.agente.comun.UsuarioAgente;
import com.co.eurekatic.common.security.AuthPrincipal;
import org.springframework.security.core.Authentication;

import java.util.Set;

/**
 * Usuario del turno, sacado de la autenticacion del JWT. Sin id de usuario no hay turno: como en el
 * resto del servicio, la sesion sin identidad se rechaza.
 */
final class UsuarioActual {

    private UsuarioActual() {
    }

    static UsuarioAgente de(Authentication autenticacion) {
        if (autenticacion != null
                && autenticacion.getPrincipal() instanceof AuthPrincipal principal
                && principal.userId() != null
                && autenticacion.getCredentials() instanceof String token) {
            Set<String> roles = principal.roles() == null ? Set.of() : principal.roles();
            return new UsuarioAgente(principal.userId(), roles, token);
        }
        throw new ErrorAgente.SinIdentidad();
    }
}
