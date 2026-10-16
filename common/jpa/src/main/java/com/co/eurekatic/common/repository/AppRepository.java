package com.co.eurekatic.common.repository;

import com.co.eurekatic.common.entity.App;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import org.springframework.stereotype.Repository;

import java.util.Collection;
import java.util.List;
import java.util.Optional;

/**
 * Spring Data JPA repository for {@link App}.
 *
 * <p>Uniqueness rule is {@code name} (the legacy
 * {@code SSO_V2.APP.name} was UNIQUE NOT NULL). We pre-check
 * with {@link #existsByName} for a friendlier 409 on insert;
 * the DB-level constraint is the source of truth under
 * concurrent inserts.
 */
@Repository
public interface AppRepository extends JpaRepository<App, Long> {

    boolean existsByName(String name);

    Optional<App> findByName(String name);

    /**
     * Listing order — by {@code id} ASC keeps the UI stable
     * across requests without relying on insertion order.
     */
    List<App> findAllByOrderByIdAsc();

    /**
     * True if the named app has a {@code role_app} binding to
     * any role in {@code roleNames}. Used by
     * {@code SsoAdminAccessManager} (via
     * {@code AppAccessService}) to gate access to this
     * console — see {@code App.roles} javadoc.
     */
    @Query("SELECT CASE WHEN COUNT(a) > 0 THEN true ELSE false END " +
            "FROM App a JOIN a.roles r WHERE a.name = :appName AND r.name IN :roleNames")
    boolean hasAnyRoleAccess(@Param("appName") String appName, @Param("roleNames") Collection<String> roleNames);

    /**
     * Apps visible to a caller whose JWT carries any of the given
     * role ids — the {@code /myApps} endpoint (auth-center) uses
     * this to compute the post-login app launcher. Same
     * role-id-membership shape as
     * {@link com.co.eurekatic.common.repository.RouteRepository#findVisibleForRoles(Collection)},
     * just over {@code role_app} instead of {@code role_route}.
     *
     * <p>Ordering: {@code id} ASC keeps the launcher's card order
     * stable across requests.
     */
    @Query("SELECT DISTINCT a FROM App a JOIN a.roles r WHERE r.id IN :roleIds ORDER BY a.id ASC")
    List<App> findVisibleForRoles(@Param("roleIds") Collection<Long> roleIds);

    /**
     * V143 (role-scoping de queries por app) — apps a los que está
     * atado un microservicio vía la M:N {@code app_microservice}
     * ({@link App#getMicroservices()}) — la relación que el admin-ui
     * de verdad usa hoy (pestaña "Microservices" del formulario de
     * App, {@code AppService#bindMicroservice}), a diferencia del FK
     * "primario" {@code Microservice#getApp()} ({@code id_app}) que
     * hoy no expone ningún formulario y por tanto queda siempre null
     * en la práctica. {@code QueryAdminService} combina ambas fuentes
     * de todas formas — ver su javadoc.
     */
    @Query("SELECT DISTINCT a FROM App a JOIN a.microservices m WHERE m.id = :microserviceId")
    List<App> findByMicroserviceId(@Param("microserviceId") Long microserviceId);
}