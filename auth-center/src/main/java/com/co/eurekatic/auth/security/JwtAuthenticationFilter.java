package com.co.eurekatic.auth.security;

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
import org.springframework.security.web.authentication.AbstractAuthenticationProcessingFilter;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.util.List;

/**
 * Reads the {@code Authorization: Bearer <token>} header on every request
 * and, if a valid JWT is present, populates the {@link SecurityContextHolder}
 * with a {@link UsernamePasswordAuthenticationToken} whose principal is the
 * {@link AuthPrincipal} extracted from the token.
 *
 * <p>This filter is intentionally non-blocking: an invalid / missing token
 * is treated as "no auth" (the request continues without a SecurityContext)
 * and the chain's authorization rules decide whether the endpoint allows
 * that. Only the {@link JsonLoginFilter} (for {@code POST /login}) and the
 * SecurityFilterChain's authorization managers reject the request.
 *
 * <p>This is the same model the api-gateway filter will use in Step 5,
 * just running in the servlet (Tomcat) thread instead of the reactive
 * (Netty) thread.
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
                    .<GrantedAuthority>map(SimpleGrantedAuthority::new)
                    .toList();
            Authentication auth =
                    new UsernamePasswordAuthenticationToken(principal, token, authorities);
            SecurityContextHolder.getContext().setAuthentication(auth);
        } catch (JwtException e) {
            // Don't reject the request here — let the chain's authorization
            // rules decide. Just log so a misconfigured client is debuggable.
            log.debug("Rejected bearer token on {} {}: {}",
                    request.getMethod(), request.getRequestURI(), e.getMessage());
            SecurityContextHolder.clearContext();
        }

        chain.doFilter(request, response);
    }
}
