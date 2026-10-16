package com.co.eurekatic.comms.security;

import jakarta.servlet.http.HttpServletRequest;

import java.time.Instant;
import java.util.Locale;
import java.util.Set;

/**
 * Usuario autenticado. {@code sub} es el correo en minusculas (topico
 * {@code user:<sub>}); {@code id} es {@code users.id_user} (claim {@code uid});
 * {@code expira} el vencimiento del JWT, que limita la vida del socket (D-1.4).
 */
public record Usuario(String sub, Long id, String nombre, Set<String> roles, String establecimiento, Instant expira) {

    static final String ATRIBUTO = Usuario.class.getName();

    public static String normalizar(String sub) {
        return sub == null ? null : sub.trim().toLowerCase(Locale.ROOT);
    }

    public static Usuario de(HttpServletRequest request) {
        if (request.getAttribute(ATRIBUTO) instanceof Usuario u) return u;
        throw new IllegalStateException("Peticion sin usuario autenticado");
    }
}
