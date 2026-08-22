package com.co.eurekatic.reporting.security;

import com.co.eurekatic.common.security.AuthPrincipal;
import com.co.eurekatic.common.security.JwtProperties;
import com.co.eurekatic.common.security.JwtTokenService;
import io.jsonwebtoken.JwtException;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.util.List;

/**
 * Revalida el JWT en cada request. Mismo patron que los filtros
 * homonimos de query-service, sso-admin y auth-center.
 *
 * <p>Ademas de autenticar, deja el token crudo como {@code credentials}
 * de la {@code Authentication}. Eso no es un detalle: el reporte no
 * consulta la base con una identidad de servicio, sino que le reenvia
 * ESTE token al query-service. Si el token no viajara, el reporte
 * tendria que resolver por su cuenta que puede ver cada usuario — que
 * es exactamente la duplicacion que este diseno evita.
 */
public class JwtAuthenticationFilter extends OncePerRequestFilter {

    private static final Logger log = LoggerFactory.getLogger(JwtAuthenticationFilter.class);

    private final JwtTokenService jwt;
    private final JwtProperties props;

    public JwtAuthenticationFilter(JwtTokenService jwt, JwtProperties props) {
        this.jwt = jwt;
        this.props = props;
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request,
                                    HttpServletResponse response,
                                    FilterChain chain) throws ServletException, IOException {
        String header = request.getHeader(props.headerName());
        if (header == null) {
            chain.doFilter(request, response);
            return;
        }
        String prefix = props.tokenPrefix();
        if (prefix != null && !prefix.isBlank() && !header.startsWith(prefix)) {
            chain.doFilter(request, response);
            return;
        }
        String token = header.substring(prefix == null ? 0 : prefix.length()).trim();
        if (token.isEmpty()) {
            chain.doFilter(request, response);
            return;
        }

        try {
            AuthPrincipal principal = jwt.parse(token);
            List<GrantedAuthority> authorities = principal.roles().stream()
                    .<GrantedAuthority>map(r -> new SimpleGrantedAuthority("ROLE_" + r))
                    .toList();
            Authentication auth =
                    new UsernamePasswordAuthenticationToken(principal, token, authorities);
            SecurityContextHolder.getContext().setAuthentication(auth);
        } catch (JwtException e) {
            log.debug("Token rechazado en {} {}: {}",
                    request.getMethod(), request.getRequestURI(), e.getMessage());
            SecurityContextHolder.clearContext();
        }

        chain.doFilter(request, response);
    }
}
