package com.co.eurekatic.ssoadmin.controller;

import com.co.eurekatic.ssoadmin.dto.AppRequest;
import com.co.eurekatic.ssoadmin.dto.AppResponse;
import com.co.eurekatic.ssoadmin.service.AppService;
import com.co.eurekatic.ssoadmin.service.AppService.MicroserviceChecked;
import com.co.eurekatic.ssoadmin.service.AppService.RoleChecked;
import com.co.eurekatic.ssoadmin.service.AppService.RouteChecked;
import com.co.eurekatic.ssoadmin.service.AppService.UserChecked;
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
 * App CRUD plus the four binding families (role / user / route /
 * microservice). Path layout mirrors the legacy
 * {@code com.co.lowcode.sso.controller.AppController} — mounted
 * under {@code /app} so the gateway route
 * {@code /sso-admin/app/**} lines up with the legacy URLs.
 *
 * <p>Every binding endpoint takes the app id in the URL plus the
 * target entity id — no batch payloads. The legacy UI worked
 * one-click-per-row and admin-ui's checkbox grid maps to that
 * 1:1. For batch imports, write a separate {@code bulk*} endpoint
 * on top of these primitives.
 */
@RestController
@RequestMapping("/app")
public class AppController {

    private final AppService service;

    public AppController(AppService service) {
        this.service = service;
    }

    /* ====================== CRUD ====================== */

    @PostMapping("/save")
    public ResponseEntity<AppResponse> create(@Valid @RequestBody AppRequest req) {
        return ResponseEntity.status(HttpStatus.CREATED).body(service.create(req));
    }

    @PutMapping("/update")
    public AppResponse update(@Valid @RequestBody AppRequest req) {
        return service.update(req);
    }

    @GetMapping("/getApps")
    public List<AppResponse> getAll() {
        return service.getAll();
    }

    @GetMapping("/{id}")
    public AppResponse getById(@PathVariable Long id) {
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
    public List<RoleChecked> getRolesForAppChecked(@PathVariable Long id) {
        return service.getRolesForAppChecked(id);
    }

    /* ====================== bindings: user ====================== */

    @PostMapping("/{id}/user/{userId}")
    public ResponseEntity<Void> bindUser(@PathVariable Long id,
                                         @PathVariable Long userId) {
        service.bindUser(id, userId);
        return ResponseEntity.noContent().build();
    }

    @DeleteMapping("/{id}/user/{userId}")
    public ResponseEntity<Void> unbindUser(@PathVariable Long id,
                                           @PathVariable Long userId) {
        service.unbindUser(id, userId);
        return ResponseEntity.noContent().build();
    }

    @GetMapping("/{id}/users/checked")
    public List<UserChecked> getUsersForAppChecked(@PathVariable Long id) {
        return service.getUsersForAppChecked(id);
    }

    /* ====================== bindings: route ====================== */

    @PostMapping("/{id}/route/{routeId}")
    public ResponseEntity<Void> bindRoute(@PathVariable Long id,
                                          @PathVariable Long routeId) {
        service.bindRoute(id, routeId);
        return ResponseEntity.noContent().build();
    }

    @DeleteMapping("/{id}/route/{routeId}")
    public ResponseEntity<Void> unbindRoute(@PathVariable Long id,
                                            @PathVariable Long routeId) {
        service.unbindRoute(id, routeId);
        return ResponseEntity.noContent().build();
    }

    @GetMapping("/{id}/routes/checked")
    public List<RouteChecked> getRoutesForAppChecked(@PathVariable Long id) {
        return service.getRoutesForAppChecked(id);
    }

    /* ====================== bindings: microservice ====================== */

    @PostMapping("/{id}/microservice/{microserviceId}")
    public ResponseEntity<Void> bindMicroservice(@PathVariable Long id,
                                                 @PathVariable Long microserviceId) {
        service.bindMicroservice(id, microserviceId);
        return ResponseEntity.noContent().build();
    }

    @DeleteMapping("/{id}/microservice/{microserviceId}")
    public ResponseEntity<Void> unbindMicroservice(@PathVariable Long id,
                                                   @PathVariable Long microserviceId) {
        service.unbindMicroservice(id, microserviceId);
        return ResponseEntity.noContent().build();
    }

    @GetMapping("/{id}/microservices/checked")
    public List<MicroserviceChecked> getMicroservicesForAppChecked(@PathVariable Long id) {
        return service.getMicroservicesForAppChecked(id);
    }
}