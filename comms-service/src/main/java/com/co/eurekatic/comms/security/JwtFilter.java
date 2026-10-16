package com.co.eurekatic.comms.security;

import com.co.eurekatic.common.security.AuthPrincipal;
import com.co.eurekatic.common.security.JwtTokenService;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.jsonwebtoken.JwtException;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.http.HttpMethod;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.time.Instant;
import java.util.Base64;
import java.util.Set;

/**
 * Verifica el Bearer con la clave publica del SSO (como ai-control-service) en
 * {@code /comms/ws-ticket} y {@code /comunicaciones/**}. {@code /comms/ws}
 * queda fuera: el socket se autentica con el ticket (D-1.2).
 */
public class JwtFilter extends OncePerRequestFilter {

    private static final ObjectMapper JSON = new ObjectMapper();
    private final JwtTokenService jwt;

    public JwtFilter(JwtTokenService jwt) {
        this.jwt = jwt;
    }

    @Override
    protected void doFilterInternal(HttpServletRequest req, HttpServletResponse res, FilterChain chain)
            throws ServletException, IOException {
        if (HttpMethod.OPTIONS.matches(req.getMethod())) {
            chain.doFilter(req, res);
            return;
        }
        String h = req.getHeader("Authorization");
        Usuario u = h != null && h.startsWith("Bearer ") ? parse(h.substring(7).trim()) : null;
        if (u == null) {
            res.setStatus(401);
            res.setContentType("application/json");
            res.setCharacterEncoding("UTF-8");
            res.getWriter().write("{\"message\":\"Sesion no valida.\"}");
            return;
        }
        req.setAttribute(Usuario.ATRIBUTO, u);
        chain.doFilter(req, res);
    }

    /** @return null si el token no es valido o no trae {@code uid}. */
    public Usuario parse(String token) {
        if (jwt == null) return null;
        try {
            AuthPrincipal p = jwt.parse(token);
            if (p.email() == null || p.userId() == null) return null;
            JsonNode claims = JSON.readTree(Base64.getUrlDecoder().decode(token.split("\\.")[1]));
            Instant exp = claims.hasNonNull("exp") ? Instant.ofEpochSecond(claims.get("exp").asLong()) : null;
            String nombre = claims.hasNonNull("name") ? claims.get("name").asText() : p.email();
            return new Usuario(Usuario.normalizar(p.email()), p.userId(), nombre,
                    p.roles() == null ? Set.of() : p.roles(), p.establishment(), exp);
        } catch (JwtException | IllegalArgumentException | IOException e) {
            return null;
        }
    }
}
