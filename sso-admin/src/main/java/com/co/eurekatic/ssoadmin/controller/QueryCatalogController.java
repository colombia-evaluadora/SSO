package com.co.eurekatic.ssoadmin.controller;

import com.co.eurekatic.common.security.AuthPrincipal;
import com.co.eurekatic.ssoadmin.dto.QueryDefinition;
import com.co.eurekatic.ssoadmin.service.QueryCatalogService;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

/**
 * Consumer-facing read endpoints for the query catalog.
 *
 * <p>Two surfaces:
 * <ul>
 *   <li>{@code GET /getQuery?uuid=...} — consumed by
 *       {@code query-service} via {@code CatalogClient} to
 *       resolve a single uuid into a usable SQL string with
 *       metadata. Per-row auth; 404 and 403 conflated to avoid
 *       making the catalog a discovery service.</li>
 *   <li>{@code GET /myQueries?microserviceId=...} — consumed by
 *       the admin-ui Queries Catalog page. Returns every query
 *       the caller is authorized to see, optionally filtered by
 *       the backing microservice instance. Empty list is a 200
 *       (not a 403) — the endpoint answers "what can I see?"
 *       and "nothing" is a legitimate answer.</li>
 * </ul>
 *
 * <p>Both are distinct from {@link QueryAdminController}, which is
 * gated by {@code ROLE_ADMIN} and used by the admin UI to manage
 * the catalog rows (CRUD + role bindings).
 *
 * <p>Email comes from the {@link AuthPrincipal} already in the
 * {@link SecurityContextHolder}, which the
 * {@code JwtAuthenticationFilter} populates before this handler
 * runs. We don't re-parse the JWT here — the gateway has
 * already validated the signature when the access token was
 * issued. Email IS the unique login identifier since the V12
 * migration (the prior {@code username} column is gone).
 */
@RestController
public class QueryCatalogController {

    private final QueryCatalogService service;

    public QueryCatalogController(QueryCatalogService service) {
        this.service = service;
    }

    @GetMapping("/getQuery")
    public ResponseEntity<QueryDefinition> getQuery(@RequestParam String uuid) {
        String email = currentEmail();
        return ResponseEntity.ok(service.resolve(uuid, email));
    }

    /**
     * Lists the queries the caller is authorized to see, optionally
     * filtered by {@code microserviceId} (the {@code MICROSERVICE.ID}
     * — not the {@code serviceId} string). When the filter is
     * omitted, queries with no instance binding ("global" queries)
     * are returned as well; the admin-ui uses the {@code null}
     * value to mean "Todas las instancias".
     */
    @GetMapping("/myQueries")
    public List<QueryDefinition> myQueries(@RequestParam(required = false) Long microserviceId) {
        return service.listForCaller(currentEmail(), microserviceId);
    }

    private static String currentEmail() {
        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        if (auth == null || !(auth.getPrincipal() instanceof AuthPrincipal principal)) {
            // Should never happen — SecurityConfig marks
            // /getQuery and /myQueries as authenticated. Falling
            // back to AccessDeniedException here keeps the failure
            // mode consistent with the role check below.
            throw new AccessDeniedException("No autenticado");
        }
        return principal.email();
    }
}