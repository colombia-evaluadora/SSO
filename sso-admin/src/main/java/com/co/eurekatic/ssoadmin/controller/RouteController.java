package com.co.eurekatic.ssoadmin.controller;

import com.co.eurekatic.ssoadmin.dto.RouteRequest;
import com.co.eurekatic.ssoadmin.dto.RouteResponse;
import com.co.eurekatic.ssoadmin.service.RouteService;
import com.co.eurekatic.ssoadmin.service.RouteService.RoleChecked;
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
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

/**
 * Route CRUD plus role bindings. Path layout mirrors the
 * legacy {@code com.co.lowcode.sso.controller.RouteController}
 * — mounted under {@code /route} so the gateway route
 * {@code /sso-admin/route/**} lines up with the legacy URLs.
 *
 * <p>The legacy had dedicated {@code /role/routes},
 * {@code /role/saveRoutes} on the RoleController. We mirror
 * them here so route management is colocated with the
 * resource being bound.
 */
@RestController
@RequestMapping("/route")
public class RouteController {

    private final RouteService service;

    public RouteController(RouteService service) {
        this.service = service;
    }

    @PostMapping("/save")
    public ResponseEntity<RouteResponse> create(@Valid @RequestBody RouteRequest req) {
        return ResponseEntity.status(HttpStatus.CREATED).body(service.create(req));
    }

    @PutMapping("/update")
    public RouteResponse update(@Valid @RequestBody RouteRequest req) {
        return service.update(req);
    }

    @GetMapping("/getRoutes")
    public List<RouteResponse> getAll() {
        return service.getAll();
    }

    /**
     * Root-level routes (idParent is null). The legacy
     * returned these via {@code getRoutesByParent(0)}.
     */
    @GetMapping("/getRoutesByParent")
    public List<RouteResponse> getByParent(@RequestParam(required = false) Long idParent) {
        if (idParent == null || idParent == 0L) {
            return service.getRoots();
        }
        return service.getChildren(idParent);
    }

    @GetMapping("/{id}")
    public RouteResponse getById(@PathVariable Long id) {
        return service.getById(id);
    }

    @DeleteMapping("/{id}")
    public ResponseEntity<Void> delete(@PathVariable Long id) {
        service.delete(id);
        return ResponseEntity.noContent().build();
    }

    /* ====================== bindings: role ====================== */

    @PostMapping("/{id}/role/{roleId}")
    public ResponseEntity<Void> bindRole(@PathVariable Long id,
                                          @PathVariable Long roleId) {
        service.bindRole(id, roleId);
        return ResponseEntity.noContent().build();
    }

    @DeleteMapping("/{id}/role/{roleId}")
    public ResponseEntity<Void> unbindRole(@PathVariable Long id,
                                            @PathVariable Long roleId) {
        service.unbindRole(id, roleId);
        return ResponseEntity.noContent().build();
    }

    @GetMapping("/{id}/roles/checked")
    public List<RoleChecked> getRolesForRouteChecked(@PathVariable Long id) {
        return service.getRolesForRouteChecked(id);
    }
}
