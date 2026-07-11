package com.co.eurekatic.ssoadmin.controller;

import com.co.eurekatic.common.security.AuthPrincipal;
import com.co.eurekatic.ssoadmin.dto.WriteDefinitionDto;
import com.co.eurekatic.ssoadmin.service.WriteCatalogService;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * Consumer-facing read endpoint for the write-definition
 * catalog. Consumed by {@code query-service} via
 * {@code CatalogClient.resolveWrite}.
 *
 * <p>Mirror of {@link QueryCatalogController}, but:
 * <ul>
 *   <li>Path is {@code /getWrite} (no {@code publicEnd}
 *       bypass — writes are never public).</li>
 *   <li>Response is {@link WriteDefinitionDto} which carries
 *       the {@code columns} / {@code keyColumns} lists already
 *       deserialized from the entity's JSON strings.</li>
 * </ul>
 *
 * <p>Authentication is required (token must parse) but no
 * {@code ROLE_ADMIN} gate — only the per-row role intersection
 * in {@link WriteCatalogService} decides.
 */
@RestController
public class WriteCatalogController {

    private final WriteCatalogService service;

    public WriteCatalogController(WriteCatalogService service) {
        this.service = service;
    }

    @GetMapping("/getWrite")
    public ResponseEntity<WriteDefinitionDto> getWrite(@RequestParam String uuid) {
        String email = currentEmail();
        return ResponseEntity.ok(service.resolve(uuid, email));
    }

    private static String currentEmail() {
        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        if (auth == null || !(auth.getPrincipal() instanceof AuthPrincipal principal)) {
            throw new AccessDeniedException("No autenticado");
        }
        return principal.email();
    }
}