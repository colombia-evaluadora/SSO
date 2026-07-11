package com.co.eurekatic.ssoadmin.controller;

import com.co.eurekatic.ssoadmin.dto.WriteDefinitionRequest;
import com.co.eurekatic.ssoadmin.dto.WriteDefinitionResponse;
import com.co.eurekatic.ssoadmin.exception.NotFoundException;
import com.co.eurekatic.ssoadmin.service.WriteDefinitionAdminService;
import com.co.eurekatic.ssoadmin.service.WriteDefinitionAdminService.RoleChecked;
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
 * WriteDefinition CRUD plus role bindings. Same shape as
 * {@link QueryAdminController}; see that class for the
 * rationale on path layout and the admin-vs-catalog split.
 *
 * <p>Mounted under {@code /write} so the gateway route
 * {@code /sso-admin/write/**} works without extra config.
 */
@RestController
@RequestMapping("/write")
public class WriteDefinitionAdminController {

    private final WriteDefinitionAdminService service;

    public WriteDefinitionAdminController(WriteDefinitionAdminService service) {
        this.service = service;
    }

    @PostMapping("/save")
    public ResponseEntity<WriteDefinitionResponse> create(@Valid @RequestBody WriteDefinitionRequest req) {
        return ResponseEntity.status(HttpStatus.CREATED).body(service.create(req));
    }

    @PutMapping("/update")
    public WriteDefinitionResponse update(@Valid @RequestBody WriteDefinitionRequest req) {
        return service.update(req);
    }

    @GetMapping("/getWrites")
    public List<WriteDefinitionResponse> getAll() {
        return service.getAll();
    }

    @GetMapping("/{id}")
    public WriteDefinitionResponse getById(@PathVariable Long id) {
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
    public List<RoleChecked> getRolesForWriteChecked(@PathVariable Long id) {
        return service.getRolesForWriteChecked(id);
    }

    /* ====================== legacy "by uuid" lookup (read-only convenience) ====================== */

    @GetMapping("/byUuid")
    public WriteDefinitionResponse getByUuid(@RequestParam String uuid) {
        return service.getAll().stream()
                .filter(w -> w.uuid().equals(uuid))
                .findFirst()
                .orElseThrow(() -> new NotFoundException("WriteDefinition", uuid));
    }
}
