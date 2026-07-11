package com.co.eurekatic.query.security;

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
 * Re-validates the JWT on every request. Identical pattern to
 * the sso-admin and auth-center filters of the same name.
 *
 * <p><b>Why this exists even though the gateway also
 * validates:</b> the query-service may be exposed directly to
 * federated partners (the spec mentions an "external ingress"
 * case). When the gateway is bypassed, the only thing standing
 * between an unauthenticated POST and the JDBC layer is THIS
 * filter — same key, same algorithm, same role mapping. The
 * catalog authorization check then enforces the per-uuid role
 * binding.
 *
 * <p>Failures here are non-fatal: an invalid or missing token
 * leaves the {@code SecurityContextHolder} empty and Spring
 * Security's {@code SecurityConfig} rules decide. By default
 * every business endpoint requires authentication, so the
 * downstream AuthorizationFilter returns 403.
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
        String token = header.substring(prefix.length()).trim();
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
            log.debug("Rejected bearer token on {} {}: {}",
                    request.getMethod(), request.getRequestURI(), e.getMessage());
            SecurityContextHolder.clearContext();
        }

        chain.doFilter(request, response);
    }
}