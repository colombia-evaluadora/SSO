package com.co.eurekatic.notificationservice.security;

import jakarta.servlet.http.HttpServletRequest;

import java.util.Locale;
import java.util.Set;

/**
 * Usuario de la peticion, resuelto del Bearer por {@link JwtUsuarioFilter}.
 * {@code sub} es el correo en minusculas: la clave de la bandeja y del topico
 * de tiempo real {@code user:<sub>}.
 */
public record UsuarioActual(String sub, Long userId, Set<String> roles) {

    static final String ATRIBUTO = UsuarioActual.class.getName();

    public static String normalizar(String sub) {
        return sub == null ? null : sub.trim().toLowerCase(Locale.ROOT);
    }

    public static UsuarioActual de(HttpServletRequest request) {
        Object u = request.getAttribute(ATRIBUTO);
        if (u instanceof UsuarioActual actual) return actual;
        throw new IllegalStateException("Peticion sin usuario autenticado");
    }
}
