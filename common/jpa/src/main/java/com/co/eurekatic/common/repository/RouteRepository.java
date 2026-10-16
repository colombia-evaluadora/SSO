package com.co.eurekatic.common.repository;

import com.co.eurekatic.common.entity.Route;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import org.springframework.stereotype.Repository;

import java.util.Collection;
import java.util.List;

/**
 * Spring Data JPA repository for {@link Route}.
 *
 * <p>The legacy supports a tree view via
 * {@code getRoutesByParent(parentId)} with {@code 0} meaning
 * "root"; in the JPA port we keep two derived methods and let
 * the service layer decide which one to call.
 */
@Repository
public interface RouteRepository extends JpaRepository<Route, Long> {

    /** All root routes (parent id is null in the modernized schema). */
    List<Route> findByIdParentIsNull();

    /** Direct children of a given parent route. */
    List<Route> findByIdParent(Long idParent);

    boolean existsByNameAndPath(String name, String path);

    /**
     * Used by the service layer to check uniqueness on update
     * (the legacy uniqueness rule on routes is name + path).
     */
    java.util.Optional<Route> findByNameAndPath(String name, String path);

    /**
     * Routes visible to a user whose JWT carries any of the
     * given role ids. The {@code /myMenu} endpoint uses this
     * to compute the per-user sidebar in one round-trip.
     *
     * <p><b>{@code role_route} is the sole source of truth for
     * menu visibility.</b> {@code role_app} (does this role have
     * permission to use an app at all — see
     * {@code SsoAdminAccessManager}) and {@code app_route}
     * (which app a route belongs to) answer a different
     * question and don't grant menu visibility by themselves.
     * This used to also be a UNION with a "broad" path — any
     * role with {@code role_app} access to an app saw every
     * route {@code app_route}-bound to it — which made the
     * per-route {@code role_route} toggle on the Route edit
     * page's Roles tab a no-op for any such role: unbinding a
     * role from one specific route did nothing because the
     * app-level grant still applied. Removed so {@code
     * role_route} is the single, predictable knob — whatever's
     * checked there is exactly what that role sees, independent
     * of app membership and independent of role name (no role,
     * including ADMIN, gets an implicit bypass).
     *
     * <p>Ordering: {@code MENUORDER} ASC breaks ties on
     * {@code ID_ROUTE} ASC — gives a stable order across
     * requests when two routes share the same
     * {@code menuOrder}.
     */
    @Query("""
            SELECT DISTINCT r FROM Route r JOIN r.roles rol
            WHERE rol.id IN :roleIds
            ORDER BY r.menuOrder ASC, r.id ASC
            """)
    List<Route> findVisibleForRoles(@Param("roleIds") Collection<Long> roleIds);

    /**
     * Scoped variant of {@link #findVisibleForRoles(Collection)}:
     * intersects with routes that are members (via
     * {@code app_route}) of the given app. Powers the
     * {@code GET /sso-admin/myMenu?app=<name>} endpoint, where the
     * SPA's {@code VITE_APP_NAME} is resolved to an
     * {@link com.co.eurekatic.common.entity.App} id on the
     * backend and used here as the scoping filter.
     *
     * <p>The grant is still {@code role_route}-only (see
     * {@link #findVisibleForRoles(Collection)}) — {@code appId}
     * here only narrows an already-granted set down to "and
     * also belongs to this app", so a role whose {@code
     * role_route} spans multiple apps' routes doesn't see
     * another app's items when the SPA asks for its own.
     * {@code app_route} membership never grants anything by
     * itself.
     *
     * <p>Same ordering as the un-scoped overload — the response
     * shape is unchanged.
     *
     * <p>Returns empty (not an error) when the caller's roles
     * don't intersect the app's route set; the endpoint surfaces
     * this as {@code 200 + []} per the {@code /myMenu} "what
     * can I see?" contract.
     */
    @Query("""
            SELECT DISTINCT r FROM Route r JOIN r.roles rol
            WHERE rol.id IN :roleIds
              AND r.id IN (
                  SELECT r2.id FROM App a2 JOIN a2.routes r2
                   WHERE a2.id = :appId
              )
            ORDER BY r.menuOrder ASC, r.id ASC
            """)
    List<Route> findVisibleForRoles(
            @Param("roleIds") Collection<Long> roleIds,
            @Param("appId") Long appId);
}
