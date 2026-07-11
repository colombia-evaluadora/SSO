package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.common.entity.Role;
import com.co.eurekatic.common.entity.Route;
import com.co.eurekatic.common.repository.RoleRepository;
import com.co.eurekatic.common.repository.RouteRepository;
import com.co.eurekatic.ssoadmin.dto.RouteRequest;
import com.co.eurekatic.ssoadmin.dto.RouteResponse;
import com.co.eurekatic.ssoadmin.exception.DuplicateException;
import com.co.eurekatic.ssoadmin.exception.NotFoundException;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;

/**
 * Route CRUD plus role bindings. Routes form a self-referencing
 * tree (each route has zero or one parent) and are gated by
 * roles. The legacy stored {@code 0} as the root sentinel;
 * the modern port normalizes incoming {@code "0"} to
 * {@code null} on write.
 */
@Service
public class RouteService {

    /**
     * Legacy sentinel for "root" parent id. We treat it as
     * "no parent" on write so JPA can treat roots uniformly.
     */
    static final Long ROOT_SENTINEL = 0L;

    private final RouteRepository routeRepo;
    private final RoleRepository roleRepo;

    public RouteService(RouteRepository routeRepo,
                        RoleRepository roleRepo) {
        this.routeRepo = routeRepo;
        this.roleRepo = roleRepo;
    }

    @Transactional
    public RouteResponse create(RouteRequest req) {
        if (routeRepo.existsByNameAndPath(req.name(), req.path())) {
            throw new DuplicateException("Route", req.name() + " (" + req.path() + ")");
        }
        Route r = new Route();
        copy(req, r);
        return RouteResponse.fromEntity(routeRepo.save(r));
    }

    @Transactional
    public RouteResponse update(RouteRequest req) {
        if (req.id() == null) {
            throw new IllegalArgumentException("id is required for update");
        }
        Route r = routeRepo.findById(req.id())
                .orElseThrow(() -> new NotFoundException("Route", req.id()));
        routeRepo.findByNameAndPath(req.name(), req.path()).ifPresent(existing -> {
            if (!existing.getId().equals(r.getId())) {
                throw new DuplicateException("Route", req.name() + " (" + req.path() + ")");
            }
        });
        copy(req, r);
        return RouteResponse.fromEntity(routeRepo.save(r));
    }

    @Transactional(readOnly = true)
    public List<RouteResponse> getAll() {
        return routeRepo.findAll().stream()
                .map(RouteResponse::fromEntity)
                .toList();
    }

    @Transactional(readOnly = true)
    public List<RouteResponse> getRoots() {
        return routeRepo.findByIdParentIsNull().stream()
                .map(RouteResponse::fromEntity)
                .toList();
    }

    @Transactional(readOnly = true)
    public List<RouteResponse> getChildren(Long idParent) {
        return routeRepo.findByIdParent(idParent).stream()
                .map(RouteResponse::fromEntity)
                .toList();
    }

    @Transactional(readOnly = true)
    public RouteResponse getById(Long id) {
        Route r = routeRepo.findById(id)
                .orElseThrow(() -> new NotFoundException("Route", id));
        return RouteResponse.fromEntity(r);
    }

    @Transactional
    public void delete(Long id) {
        if (!routeRepo.existsById(id)) {
            throw new NotFoundException("Route", id);
        }
        routeRepo.deleteById(id);
    }

    /* ====================== bindings: role ====================== */

    @Transactional
    public void bindRole(Long routeId, Long roleId) {
        Route r = routeRepo.findById(routeId)
                .orElseThrow(() -> new NotFoundException("Route", routeId));
        Role role = roleRepo.findById(roleId)
                .orElseThrow(() -> new NotFoundException("Role", roleId));
        r.addRole(role);
        routeRepo.save(r);
    }

    @Transactional
    public void unbindRole(Long routeId, Long roleId) {
        Route r = routeRepo.findById(routeId)
                .orElseThrow(() -> new NotFoundException("Route", routeId));
        Role role = roleRepo.findById(roleId)
                .orElseThrow(() -> new NotFoundException("Role", roleId));
        r.removeRole(role);
        routeRepo.save(r);
    }

    /**
     * All roles with a {@code checked} flag — drives the
     * multi-select UI for editing which roles can see this
     * route.
     */
    @Transactional(readOnly = true)
    public List<RoleChecked> getRolesForRouteChecked(Long routeId) {
        Route r = routeRepo.findById(routeId)
                .orElseThrow(() -> new NotFoundException("Route", routeId));
        Set<Long> bound = r.getRoles().stream()
                .map(Role::getId)
                .collect(Collectors.toCollection(LinkedHashSet::new));
        return roleRepo.findAll().stream()
                .map(role -> new RoleChecked(role.getId(), role.getName(), bound.contains(role.getId())))
                .toList();
    }

    /* ------------- internals ------------- */

    private void copy(RouteRequest req, Route r) {
        r.setName(req.name());
        r.setIcon(req.icon());
        r.setPath(req.path());
        r.setMenuOrder(req.menuOrder() == null ? 0 : req.menuOrder());
        r.setType(req.type());
        // Legacy "0" → null (root).
        Long parent = req.idParent();
        r.setIdParent(parent == null || ROOT_SENTINEL.equals(parent) ? null : parent);
    }

    public record RoleChecked(Long roleId, String name, boolean checked) {}
}
