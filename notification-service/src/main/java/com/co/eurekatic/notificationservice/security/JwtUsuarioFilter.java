package com.co.eurekatic.notificationservice.security;

import com.co.eurekatic.common.security.AuthPrincipal;
import com.co.eurekatic.common.security.JwtTokenService;
import io.jsonwebtoken.JwtException;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpMethod;
import org.springframework.http.MediaType;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.Set;

/**
 * Autentica las rutas de usuario ({@code /notificaciones/**}) verificando la
 * firma del Bearer con la clave publica del SSO, igual que ai-control-service.
 * No se confia en las cabeceras {@code X-Authenticated-*} del gateway porque el
 * puerto del servicio es alcanzable dentro de la red de compose.
 *
 * <p>Solo cubre estas rutas: {@code /actuator/**} sigue como estaba.
 */
public class JwtUsuarioFilter extends OncePerRequestFilter {

    private static final Logger log = LoggerFactory.getLogger(JwtUsuarioFilter.class);
    private static final String PREFIJO = "Bearer ";

    private final JwtTokenService jwt;

    /** {@code jwt} null = sin clave configurada: las rutas responden 503. */
    public JwtUsuarioFilter(JwtTokenService jwt) {
        this.jwt = jwt;
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response,
                                    FilterChain chain) throws ServletException, IOException {
        if (HttpMethod.OPTIONS.matches(request.getMethod())) {
            chain.doFilter(request, response);
            return;
        }
        if (jwt == null) {
            responder(response, HttpServletResponse.SC_SERVICE_UNAVAILABLE,
                    "El servicio de notificaciones no tiene configurada la clave publica del SSO.");
            return;
        }
        String header = request.getHeader("Authorization");
        if (header == null || !header.startsWith(PREFIJO) || header.length() <= PREFIJO.length()) {
            responder(response, HttpServletResponse.SC_UNAUTHORIZED, "Sesion no valida.");
            return;
        }
        try {
            AuthPrincipal p = jwt.parse(header.substring(PREFIJO.length()).trim());
            if (p.email() == null || p.email().isBlank()) {
                responder(response, HttpServletResponse.SC_UNAUTHORIZED, "Sesion no valida.");
                return;
            }
            request.setAttribute(UsuarioActual.ATRIBUTO, new UsuarioActual(
                    UsuarioActual.normalizar(p.email()), p.userId(),
                    p.roles() == null ? Set.of() : p.roles()));
        } catch (JwtException | IllegalArgumentException e) {
            log.debug("Token rechazado en {} {}: {}", request.getMethod(), request.getRequestURI(), e.getMessage());
            responder(response, HttpServletResponse.SC_UNAUTHORIZED, "Sesion no valida.");
            return;
        }
        chain.doFilter(request, response);
    }

    private static void responder(HttpServletResponse response, int status, String mensaje) throws IOException {
        response.setStatus(status);
        response.setContentType(MediaType.APPLICATION_JSON_VALUE);
        response.setCharacterEncoding(StandardCharsets.UTF_8.name());
        response.getWriter().write("{\"message\":\"" + mensaje.replace("\"", "'") + "\"}");
    }
}
