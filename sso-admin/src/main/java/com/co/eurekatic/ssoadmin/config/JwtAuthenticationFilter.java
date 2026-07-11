package com.co.eurekatic.ssoadmin.config;

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
 * Reads the {@code Authorization: Bearer <token>} header on every
 * request and, if a valid JWT is present, populates
 * {@link SecurityContextHolder} with a
 * {@link UsernamePasswordAuthenticationToken} whose principal is
 * the {@link AuthPrincipal} extracted from the token.
 *
 * <p>Identical pattern to
 * {@code auth-center/.../JwtAuthenticationFilter.java}. The two
 * filters are intentionally separate so sso-admin and auth-center
 * can be deployed and scaled independently.
 *
 * <p>The filter is non-blocking: an invalid or missing token is
 * treated as "no auth" and the chain's authorization rules
 * decide. {@link SecurityConfig} requires
 * {@code hasRole("ADMIN")} on every business endpoint, so a
 * missing or invalid token is rejected with 401/403 by Spring
 * Security's standard exception handling.
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
            // Spring Security's hasRole("ADMIN") expects the
            // authority "ROLE_ADMIN" — we add the prefix here so
            // the security expression in SecurityConfig reads
            // naturally. hasAuthority("ADMIN") works too but
            // hasRole() is the more common idiom.
            List<GrantedAuthority> authorities = principal.roles().stream()
                    .<GrantedAuthority>map(r -> new SimpleGrantedAuthority("ROLE_" + r))
                    .toList();
            Authentication auth =
                    new UsernamePasswordAuthenticationToken(principal, token, authorities);
            SecurityContextHolder.getContext().setAuthentication(auth);
        } catch (JwtException e) {
            // Don't reject here — let the chain's authorization
            // rules decide. Log so a misconfigured client is
            // debuggable.
            log.debug("Rejected bearer token on {} {}: {}",
                    request.getMethod(), request.getRequestURI(), e.getMessage());
            SecurityContextHolder.clearContext();
        }

        chain.doFilter(request, response);
    }
}
