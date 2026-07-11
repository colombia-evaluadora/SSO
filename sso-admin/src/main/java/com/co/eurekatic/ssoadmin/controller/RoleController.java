package com.co.eurekatic.ssoadmin.controller;

import com.co.eurekatic.ssoadmin.dto.RoleRequest;
import com.co.eurekatic.ssoadmin.dto.RoleResponse;
import com.co.eurekatic.ssoadmin.dto.UserResponse;
import com.co.eurekatic.ssoadmin.service.RoleAdminService;
import com.co.eurekatic.ssoadmin.service.RoleAdminService.UserRoleChecked;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

/**
 * Role CRUD + user↔role binding views. Phase 1 covers only
 * the user bindings; endpoint/route bindings land in Phase 2.
 * Path layout mirrors the legacy
 * {@code com.co.lowcode.sso.controller.RoleController}.
 */
@RestController
@RequestMapping("/role")
public class RoleController {

    private final RoleAdminService service;

    public RoleController(RoleAdminService service) {
        this.service = service;
    }

    @PostMapping("/createRole")
    public ResponseEntity<RoleResponse> createRole(@Valid @RequestBody RoleRequest req) {
        RoleResponse created = service.createRole(req);
        return ResponseEntity.status(HttpStatus.CREATED).body(created);
    }

    @PutMapping("/updateRole")
    public RoleResponse updateRole(@Valid @RequestBody RoleRequest req) {
        return service.updateRole(req);
    }

    @GetMapping("/getRoles")
    public List<RoleResponse> getRoles() {
        return service.getRoles();
    }

    /**
     * Same as {@link #getRoles} but excludes
     * {@code ADMIN_USUARIOS_OPERADORAS} — the
     * "regular admin" view of the role catalog.
     */
    @GetMapping("/getRolesOwn")
    public List<RoleResponse> getRolesOwn() {
        return service.getRolesOwn();
    }

    @GetMapping("/users")
    public List<UserResponse> getUsersForRole(@RequestParam Long roleId) {
        return service.getUsersForRole(roleId);
    }

    /**
     * All users with a {@code checked} flag — drives the
     * multi-select UI for editing role membership.
     */
    @GetMapping("/users/checked")
    public List<UserRoleChecked> getUsersForRoleChecked(@RequestParam Long roleId) {
        return service.getUsersForRoleChecked(roleId);
    }
}
