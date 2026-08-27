package com.co.eurekatic.gateway.routing;

import com.co.eurekatic.common.security.AuthPrincipal;
import org.springframework.cloud.gateway.filter.GatewayFilterChain;
import org.springframework.cloud.gateway.filter.GlobalFilter;
import org.springframework.core.Ordered;
import org.springframework.http.server.reactive.ServerHttpRequest;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.ReactiveSecurityContextHolder;
import org.springframework.stereotype.Component;
import org.springframework.web.server.ServerWebExchange;
import reactor.core.publisher.Mono;

/**
 * Global filter that propagates the authenticated user to downstream
 * services via request headers. Downstream services that need to know
 * the calling user (e.g. auth-center's {@code /getInfoUser} fallback
 * path, or any business service that audits actions) can read these
 * headers without having to re-validate the JWT.
 *
 * <p>Headers added:
 * <ul>
 *   <li>{@code X-Authenticated-User} — the JWT subject ({@code sub} claim).
 *       Post-V12 this is the user's email; the legacy {@code username}
 *       header value is gone since the column was dropped.</li>
 *   <li>{@code X-Authenticated-Roles} — comma-separated role names</li>
 *   <li>{@code X-Authenticated-Token-Type} — {@code access} or {@code api}</li>
 *   <li>{@code X-Authenticated-User-Id} — the numeric {@code uid} claim
 *       (V29). Downstream services that need the userId (e.g. for
 *       auditing or for passing into a stored procedure) read it
 *       here without a DB lookup. Empty when the token didn't carry
 *       the claim (legacy tokens); downstream consumers MUST tolerate
 *       an empty header and treat it as "anonymous-ish".</li>
 *   <li>{@code X-Authenticated-Family-Id} — V-audit-ctx-4 (sesiones
 *       reales), el UUID del refresh-token family ({@code fid}
 *       claim). Lo leen los write-sites (query-service,
 *       file-service, sso-admin) para mergear
 *       {@code sesion_id}/{@code familia} dentro de
 *       {@code app.contexto} y que lleguen como columnas
 *       propias a {@code auditoria.audit_log}. Vacío cuando el
 *       token no llevaba el claim (legacy pre-V-audit-ctx-4).</li>
 * </ul>
 *
 * <p>These headers are advisory only — the downstream service MUST
 * still validate the JWT on its own trust boundary, or trust the
 * gateway's headers ONLY when the downstream is reachable only via
 * the gateway (and the network path is locked down). The gateway is
 * the trust boundary; headers can be spoofed by anyone that can reach
 * the downstream service directly.
 */
@Component
public class UserForwardingGlobalFilter implements GlobalFilter, Ordered {

    static final String HEADER_USER = "X-Authenticated-User";
    static final String HEADER_USER_ID = "X-Authenticated-User-Id";
    static final String HEADER_ROLES = "X-Authenticated-Roles";
    static final String HEADER_TOKEN_TYPE = "X-Authenticated-Token-Type";
    static final String HEADER_FAMILY_ID = "X-Authenticated-Family-Id";

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        // Compute the request to forward: original if no auth,
        // mutated with user headers if authenticated. Then call
        // chain.filter exactly once. We do NOT use switchIfEmpty
        // on the result of chain.filter because chain.filter
        // returns Mono<Void> which completes empty on success —
        // that would re-invoke the chain.
        Mono<ServerHttpRequest> requestToForward = ReactiveSecurityContextHolder.getContext()
                .map(ctx -> ctx.getAuthentication())
                .filter(Authentication::isAuthenticated)
                .map(Authentication::getPrincipal)
                .ofType(AuthPrincipal.class)
                .map(principal -> {
                    var mutator = exchange.getRequest().mutate()
                            // AuthPrincipal.email() — the JWT sub since V12
                            // carries the user's email (the legacy username
                            // column is gone). Header name is unchanged so
                            // existing downstream parsers keep working.
                            .header(HEADER_USER, principal.email())
                            .header(HEADER_ROLES, String.join(",", principal.roles()))
                            .header(HEADER_TOKEN_TYPE, principal.tokenType());
                    // V29: forward the numeric userId. Empty
                    // string when the token didn't carry uid
                    // (legacy). Downstream consumers MUST handle
                    // empty as "unknown".
                    if (principal.userId() != null) {
                        mutator.header(HEADER_USER_ID, principal.userId().toString());
                    } else {
                        mutator.header(HEADER_USER_ID, "");
                    }
                    // V-audit-ctx-4 (sesiones reales): forward
                    // familyId (vacío en tokens legacy).
                    // Mismo contrato que userId -- "ausente" se
                    // distingue de "presente pero vacío" sólo
                    // porque sí lo emitimos siempre como string
                    // vacío cuando no hay claim.
                    if (principal.familyId() != null) {
                        mutator.header(HEADER_FAMILY_ID, principal.familyId());
                    } else {
                        mutator.header(HEADER_FAMILY_ID, "");
                    }
                    return mutator.build();
                })
                .defaultIfEmpty(exchange.getRequest());

        return requestToForward
                .map(req -> exchange.mutate().request(req).build())
                .flatMap(chain::filter);
    }

    @Override
    public int getOrder() {
        // Run AFTER the JWT filter has populated the SecurityContext.
        // ReactiveSecurityContextHolder is populated by
        // {@link ReactiveJwtAuthenticationFilter} which lives at
        // SecurityWebFiltersOrder.AUTHENTICATION. Global filters in
        // Spring Cloud Gateway run after the security filter chain,
        // so this ordering is fine.
        return Ordered.LOWEST_PRECEDENCE - 100;
    }
}
