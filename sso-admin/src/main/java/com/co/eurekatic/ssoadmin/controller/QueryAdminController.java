package com.co.eurekatic.ssoadmin.controller;

import com.co.eurekatic.ssoadmin.dto.QueryRequest;
import com.co.eurekatic.ssoadmin.dto.QueryResponse;
import com.co.eurekatic.ssoadmin.exception.NotFoundException;
import com.co.eurekatic.ssoadmin.service.QueryAdminService;
import com.co.eurekatic.ssoadmin.service.QueryAdminService.RoleChecked;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

/**
 * Query catalog CRUD. Path layout mirrors the legacy
 * {@code com.co.lowcode.sso.controller.EndpointController}
 * convention so the gateway route {@code /sso-admin/query/**}
 * lines up with what the admin UI already expects.
 *
 * <p>Distinct from {@code QueryCatalogController}: this is the
 * <b>admin</b> surface (manage the catalog), mounted under
 * {@code /query}, gated by {@code hasRole("ADMIN")}. The
 * catalog endpoint that {@code query-service} calls is a
 * separate {@code GET /getQuery} gated only by JWT validity +
 * the {@code ROLE_QUERY} join.
 */
@RestController
@RequestMapping("/query")
public class QueryAdminController {

    private final QueryAdminService service;

    public QueryAdminController(QueryAdminService service) {
        this.service = service;
    }

    @PostMapping("/save")
    public ResponseEntity<QueryResponse> create(@Valid @RequestBody QueryRequest req) {
        return ResponseEntity.status(HttpStatus.CREATED).body(service.create(req));
    }

    @PutMapping("/update")
    public QueryResponse update(@Valid @RequestBody QueryRequest req) {
        return service.update(req);
    }

    @GetMapping("/getQueries")
    public List<QueryResponse> getAll() {
        return service.getAll();
    }

    @GetMapping("/{id}")
    public QueryResponse getById(@PathVariable Long id) {
        return service.getById(id);
    }

    @DeleteMapping("/{id}")
    public ResponseEntity<Void> delete(@PathVariable Long id) {
        service.delete(id);
        return ResponseEntity.noContent().build();
    }

    /* ====================== bindings: role ====================== */

    @PostMapping("/{id}/role/{roleId}")
    public ResponseEntity<Void> bindRole(@PathVariable Long id, @PathVariable Long roleId) {
        service.bindRole(id, roleId);
        return ResponseEntity.noContent().build();
    }

    @DeleteMapping("/{id}/role/{roleId}")
    public ResponseEntity<Void> unbindRole(@PathVariable Long id, @PathVariable Long roleId) {
        service.unbindRole(id, roleId);
        return ResponseEntity.noContent().build();
    }

    @GetMapping("/{id}/roles/checked")
    public List<RoleChecked> getRolesForQueryChecked(@PathVariable Long id) {
        return service.getRolesForQueryChecked(id);
    }

    /* ====================== legacy "by uuid" lookup (read-only convenience) ====================== */

    @GetMapping("/byUuid")
    public QueryResponse getByUuid(@org.springframework.web.bind.annotation.RequestParam String uuid) {
        return service.getAll().stream()
                .filter(q -> q.uuid().equals(uuid))
                .findFirst()
                .orElseThrow(() -> new NotFoundException("Query", uuid));
    }
}
