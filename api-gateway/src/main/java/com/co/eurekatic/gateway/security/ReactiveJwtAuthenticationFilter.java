package com.co.eurekatic.gateway.security;

import com.co.eurekatic.common.security.AuthPrincipal;
import com.co.eurekatic.common.security.JwtProperties;
import com.co.eurekatic.common.security.JwtTokenService;
import io.jsonwebtoken.JwtException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.ReactiveSecurityContextHolder;
import org.springframework.security.core.context.SecurityContextImpl;
import org.springframework.web.server.ServerWebExchange;
import org.springframework.web.server.WebFilter;
import org.springframework.web.server.WebFilterChain;
import reactor.core.publisher.Mono;

import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.List;
import java.util.Map;

/**
 * Reactive equivalent of {@code auth-center}'s servlet
 * {@code JwtAuthenticationFilter}. Inspects the {@code Authorization}
 * header on every request and, if a valid Bearer token is present,
 * populates the reactive {@link ReactiveSecurityContextHolder} with a
 * {@link UsernamePasswordAuthenticationToken} whose principal is the
 * {@link AuthPrincipal} extracted from the token.
 *
 * <p>An invalid token causes the filter to return a 401 directly,
 * <em>not</em> delegate to Spring Security's chain — the gateway is
 * the trust boundary and we want a deterministic, JSON-shaped error
 * rather than a redirect or HTML page.
 */
public class ReactiveJwtAuthenticationFilter implements WebFilter {

    private static final Logger log = LoggerFactory.getLogger(ReactiveJwtAuthenticationFilter.class);

    private final JwtTokenService jwt;
    private final JwtProperties props;

    public ReactiveJwtAuthenticationFilter(JwtTokenService jwt, JwtProperties props) {
        this.jwt = jwt;
        this.props = props;
    }

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, WebFilterChain chain) {
        String header = exchange.getRequest().getHeaders().getFirst(props.headerName());
        if (header == null) {
            // No token: continue down the chain. The SecurityWebFilterChain
            // will return 401 for protected paths.
            return chain.filter(exchange);
        }
        String prefix = props.tokenPrefix();
        if (prefix != null && !prefix.isBlank() && !header.startsWith(prefix)) {
            return chain.filter(exchange);
        }
        String token = header.substring(prefix.length()).trim();
        if (token.isEmpty()) {
            return chain.filter(exchange);
        }

        try {
            AuthPrincipal principal = jwt.parse(token);
            List<GrantedAuthority> authorities = principal.roles().stream()
                    .<GrantedAuthority>map(SimpleGrantedAuthority::new)
                    .toList();
            Authentication auth =
                    new UsernamePasswordAuthenticationToken(principal, token, authorities);
            SecurityContextImpl context = new SecurityContextImpl(auth);
            return chain.filter(exchange)
                    .contextWrite(ReactiveSecurityContextHolder.withSecurityContext(Mono.just(context)));
        } catch (JwtException e) {
            log.debug("Rejected bearer token on {} {}: {}",
                    exchange.getRequest().getMethod().name(),
                    exchange.getRequest().getPath().value(),
                    e.getMessage());
            return unauthorized(exchange, e.getMessage());
        }
    }

    private Mono<Void> unauthorized(ServerWebExchange exchange, String reason) {
        exchange.getResponse().setStatusCode(HttpStatus.UNAUTHORIZED);
        exchange.getResponse().getHeaders().set(HttpHeaders.CONTENT_TYPE, MediaType.APPLICATION_JSON_VALUE);
        byte[] body = String.format(
                "{\"timestamp\":\"%s\",\"status\":401,\"error\":\"invalid_token\",\"message\":\"%s\"}",
                Instant.now(), reason == null ? "Invalid token" : escape(reason))
                .getBytes(StandardCharsets.UTF_8);
        return exchange.getResponse().writeWith(Mono.just(exchange.getResponse().bufferFactory().wrap(body)));
    }

    private static String escape(String s) {
        return s.replace("\\", "\\\\").replace("\"", "\\\"");
    }

    /** Useful for tests that want a known request body shape. */
    public Map<String, String> probe() {
        return Map.of("filter", "ok");
    }
}
