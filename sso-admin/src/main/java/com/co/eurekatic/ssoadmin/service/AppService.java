package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.common.entity.App;
import com.co.eurekatic.common.entity.Microservice;
import com.co.eurekatic.common.entity.Role;
import com.co.eurekatic.common.entity.Route;
import com.co.eurekatic.common.entity.User;
import com.co.eurekatic.common.repository.AppRepository;
import com.co.eurekatic.common.repository.MicroserviceRepository;
import com.co.eurekatic.common.repository.RoleRepository;
import com.co.eurekatic.common.repository.RouteRepository;
import com.co.eurekatic.common.repository.UserRepository;
import com.co.eurekatic.ssoadmin.dto.AppRequest;
import com.co.eurekatic.ssoadmin.dto.AppResponse;
import com.co.eurekatic.ssoadmin.exception.DuplicateException;
import com.co.eurekatic.ssoadmin.exception.NotFoundException;
import org.springframework.cache.Cache;
import org.springframework.cache.CacheManager;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;

/**
 * App CRUD plus the four binding families (roles, users, routes,
 * microservices) that mirror the legacy {@code SSO_V2} model.
 *
 * <p>Uniqueness: legacy rule is {@code name}. We pre-check with
 * {@link AppRepository#existsByName} for a friendlier 409; the
 * DB-level {@code UNIQUE NOT NULL} on {@code app.name} is the
 * source of truth under concurrent inserts.
 *
 * <p>Why the four binding methods all live here (and not on the
 * owning services like {@link RouteService} or {@link RoleAdminService}):
 * in the legacy SSO_V2 UI, bindings were managed from the App
 * detail page (e.g. "this app's routes", "this app's users") —
 * colocating the endpoints here keeps that flow intact without
 * adding cross-controller dependencies.
 *
 * <p>Each binding endpoint accepts a single id and toggles the
 * join — no batch payload. The legacy UI used one-click toggles
 * per row, and admin-ui's checkbox grid maps to that directly.
 */
@Service
public class AppService {

    private final AppRepository appRepo;
    private final RoleRepository roleRepo;
    private final UserRepository userRepo;
    private final RouteRepository routeRepo;
    private final MicroserviceRepository microserviceRepo;
    private final CacheManager cacheManager;

    public AppService(AppRepository appRepo,
                      RoleRepository roleRepo,
                      UserRepository userRepo,
                      RouteRepository routeRepo,
                      MicroserviceRepository microserviceRepo,
                      CacheManager cacheManager) {
        this.appRepo = appRepo;
        this.roleRepo = roleRepo;
        this.userRepo = userRepo;
        this.routeRepo = routeRepo;
        this.microserviceRepo = microserviceRepo;
        this.cacheManager = cacheManager;
    }

    /* ====================== CRUD ====================== */

    @Transactional
    public AppResponse create(AppRequest req) {
        if (appRepo.existsByName(req.name())) {
            throw new DuplicateException("App", req.name());
        }
        App app = new App();
        copy(req, app);
        return AppResponse.fromEntity(appRepo.save(app));
    }

    @Transactional
    public AppResponse update(AppRequest req) {
        if (req.id() == null) {
            throw new IllegalArgumentException("id is required for update");
        }
        App app = appRepo.findById(req.id())
                .orElseThrow(() -> new NotFoundException("App", req.id()));
        // Allow same name only for the same row.
        appRepo.findByName(req.name()).ifPresent(existing -> {
            if (!existing.getId().equals(app.getId())) {
                throw new DuplicateException("App", req.name());
            }
        });
        copy(req, app);
        return AppResponse.fromEntity(appRepo.save(app));
    }

    @Transactional(readOnly = true)
    public List<AppResponse> getAll() {
        return appRepo.findAllByOrderByIdAsc().stream()
                .map(AppResponse::fromEntity)
                .toList();
    }

    @Transactional(readOnly = true)
    public AppResponse getById(Long id) {
        return AppResponse.fromEntity(appRepo.findById(id)
                .orElseThrow(() -> new NotFoundException("App", id)));
    }

    @Transactional
    public void delete(Long id) {
        if (!appRepo.existsById(id)) {
            throw new NotFoundException("App", id);
        }
        appRepo.deleteById(id);
    }

    /* ====================== bindings: role ====================== */

    @Transactional
    public void bindRole(Long appId, Long roleId) {
        App app = loadApp(appId);
        Role role = roleRepo.findById(roleId)
                .orElseThrow(() -> new NotFoundException("Role", roleId));
        app.addRole(role);
        evictAppAccessCache(app.getName(), role.getName());
    }

    @Transactional
    public void unbindRole(Long appId, Long roleId) {
        App app = loadApp(appId);
        Role role = roleRepo.findById(roleId)
                .orElseThrow(() -> new NotFoundException("Role", roleId));
        app.removeRole(role);
        evictAppAccessCache(app.getName(), role.getName());
    }

    /**
     * Invalidates {@code AppAccessService}'s cached "does this role
     * have access to this app" entry right away, so
     * {@code SsoAdminAccessManager} sees the change on the very
     * next request instead of waiting out the TTL. The key shape
     * (`appName + ":" + roleName`) must stay in sync with
     * {@code AppAccessService#hasAccess}'s {@code @Cacheable} key.
     */
    private void evictAppAccessCache(String appName, String roleName) {
        Cache cache = cacheManager.getCache("app-access");
        if (cache != null) {
            cache.evict(appName + ":" + roleName);
        }
    }

    @Transactional(readOnly = true)
    public List<RoleChecked> getRolesForAppChecked(Long appId) {
        App app = loadApp(appId);
        Set<Long> bound = app.getRoles().stream()
                .map(Role::getId)
                .collect(Collectors.toCollection(LinkedHashSet::new));
        return roleRepo.findAll().stream()
                .map(r -> new RoleChecked(r.getId(), r.getName(), bound.contains(r.getId())))
                .toList();
    }

    /* ====================== bindings: user ====================== */

    @Transactional
    public void bindUser(Long appId, Long userId) {
        App app = loadApp(appId);
        User user = userRepo.findById(userId)
                .orElseThrow(() -> new NotFoundException("User", userId));
        app.addUser(user);
    }

    @Transactional
    public void unbindUser(Long appId, Long userId) {
        App app = loadApp(appId);
        User user = userRepo.findById(userId)
                .orElseThrow(() -> new NotFoundException("User", userId));
        app.removeUser(user);
    }

    @Transactional(readOnly = true)
    public List<UserChecked> getUsersForAppChecked(Long appId) {
        App app = loadApp(appId);
        Set<Long> bound = app.getUsers().stream()
                .map(User::getId)
                .collect(Collectors.toCollection(LinkedHashSet::new));
        return userRepo.findAll().stream()
                .map(u -> new UserChecked(
                        u.getId(),
                        u.getFullName(),
                        u.getEmail(),
                        bound.contains(u.getId())))
                .toList();
    }

    /* ====================== bindings: route ====================== */

    @Transactional
    public void bindRoute(Long appId, Long routeId) {
        App app = loadApp(appId);
        Route route = routeRepo.findById(routeId)
                .orElseThrow(() -> new NotFoundException("Route", routeId));
        app.addRoute(route);
    }

    @Transactional
    public void unbindRoute(Long appId, Long routeId) {
        App app = loadApp(appId);
        Route route = routeRepo.findById(routeId)
                .orElseThrow(() -> new NotFoundException("Route", routeId));
        app.removeRoute(route);
    }

    @Transactional(readOnly = true)
    public List<RouteChecked> getRoutesForAppChecked(Long appId) {
        App app = loadApp(appId);
        Set<Long> bound = app.getRoutes().stream()
                .map(Route::getId)
                .collect(Collectors.toCollection(LinkedHashSet::new));
        return routeRepo.findAll().stream()
                .map(r -> new RouteChecked(r.getId(), r.getName(), r.getPath(), bound.contains(r.getId())))
                .toList();
    }

    /* ====================== bindings: microservice ====================== */

    @Transactional
    public void bindMicroservice(Long appId, Long microserviceId) {
        App app = loadApp(appId);
        Microservice m = microserviceRepo.findById(microserviceId)
                .orElseThrow(() -> new NotFoundException("Microservice", microserviceId));
        app.addMicroservice(m);
    }

    @Transactional
    public void unbindMicroservice(Long appId, Long microserviceId) {
        App app = loadApp(appId);
        Microservice m = microserviceRepo.findById(microserviceId)
                .orElseThrow(() -> new NotFoundException("Microservice", microserviceId));
        app.removeMicroservice(m);
    }

    @Transactional(readOnly = true)
    public List<MicroserviceChecked> getMicroservicesForAppChecked(Long appId) {
        App app = loadApp(appId);
        Set<Long> bound = app.getMicroservices().stream()
                .map(Microservice::getId)
                .collect(Collectors.toCollection(LinkedHashSet::new));
        return microserviceRepo.findAll().stream()
                .map(m -> new MicroserviceChecked(m.getId(), m.getServiceId(), m.getKind(), bound.contains(m.getId())))
                .toList();
    }

    /* ====================== helpers ====================== */

    private App loadApp(Long id) {
        return appRepo.findById(id)
                .orElseThrow(() -> new NotFoundException("App", id));
    }

    private static void copy(AppRequest req, App app) {
        app.setName(req.name());
        app.setDescription(req.description());
        app.setLaunchUrl(req.launchUrl());
    }

    /* ====================== checked-list records ====================== */

    // NOTE: the id-field names use the suffixed convention
    // (roleId / userId / routeId / microserviceId) to match the
    // rest of the module — see EndpointService.RoleChecked,
    // RouteService.RoleChecked, RoleAdminService.UserRoleChecked.
    // The frontend types in admin-ui/src/api/types.ts depend on
    // these exact names. (An earlier draft used bare `id`, which
    // caused the admin-ui Apps binding drawer to silently fire
    // POST /app/{id}/role/undefined at runtime — see
    // admin-ui/scripts/smoke-apps-browser-flow.md.)
    public record RoleChecked(Long roleId, String name, boolean checked) {}
    /**
     * Per-app checked-listing of users. The {@code username}
     * slot was removed in the V12 migration — we expose
     * {@code fullName} + {@code email} (matching the
     * {@code AppUserChecked} TS type in admin-ui/src/api/types.ts).
     */
    public record UserChecked(Long userId, String fullName, String email, boolean checked) {}
    public record RouteChecked(Long routeId, String name, String path, boolean checked) {}
    public record MicroserviceChecked(Long microserviceId, String serviceId, String kind, boolean checked) {}
}