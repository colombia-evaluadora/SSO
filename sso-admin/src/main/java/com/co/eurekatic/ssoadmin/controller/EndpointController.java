package com.co.eurekatic.ssoadmin.controller;

import com.co.eurekatic.ssoadmin.dto.EndpointRequest;
import com.co.eurekatic.ssoadmin.dto.EndpointResponse;
import com.co.eurekatic.ssoadmin.service.EndpointService;
import com.co.eurekatic.ssoadmin.service.EndpointService.MicroserviceChecked;
import com.co.eurekatic.ssoadmin.service.EndpointService.RoleChecked;
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
 * Endpoint CRUD plus microservice and role bindings. Path
 * layout mirrors the legacy
 * {@code com.co.lowcode.sso.controller.EndpointController} —
 * mounted under {@code /endpoint} so the gateway route
 * {@code /sso-admin/endpoint/**} lines up with the legacy URLs.
 *
 * <p>The legacy had dedicated {@code /role/endpoints},
 * {@code /role/addEndpoint}, {@code /role/saveEndpoints} on
 * the RoleController. We mirror them here so endpoint
 * management is colocated with the resource being bound.
 */
@RestController
@RequestMapping("/endpoint")
public class EndpointController {

    private final EndpointService service;

    public EndpointController(EndpointService service) {
        this.service = service;
    }

    @PostMapping("/save")
    public ResponseEntity<EndpointResponse> create(@Valid @RequestBody EndpointRequest req) {
        return ResponseEntity.status(HttpStatus.CREATED).body(service.create(req));
    }

    @PutMapping("/update")
    public EndpointResponse update(@Valid @RequestBody EndpointRequest req) {
        return service.update(req);
    }

    @GetMapping("/getEndpoints")
    public List<EndpointResponse> getAll() {
        return service.getAll();
    }

    @GetMapping("/{id}")
    public EndpointResponse getById(@PathVariable Long id) {
        return service.getById(id);
    }

    @DeleteMapping("/{id}")
    public ResponseEntity<Void> delete(@PathVariable Long id) {
        service.delete(id);
        return ResponseEntity.noContent().build();
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
    public List<MicroserviceChecked> getMicroservicesForEndpointChecked(@PathVariable Long id) {
        return service.getMicroservicesForEndpointChecked(id);
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
    public List<RoleChecked> getRolesForEndpointChecked(@PathVariable Long id) {
        return service.getRolesForEndpointChecked(id);
    }

    /* ====================== legacy "by name" lookups (read-only convenience) ====================== */

    @GetMapping("/bySignature")
    public EndpointResponse getBySignature(@RequestParam String path,
                                           @RequestParam String method,
                                           @RequestParam(required = false) String description) {
        return service.getAll().stream()
                .filter(e -> e.path().equals(path)
                        && e.method().equalsIgnoreCase(method)
                        && (description == null || description.equals(e.description())))
                .findFirst()
                .orElseThrow(() -> new com.co.eurekatic.ssoadmin.exception.NotFoundException(
                        "Endpoint", method + " " + path));
    }
}
