package com.co.eurekatic.common.repository;

import com.co.eurekatic.common.entity.Endpoint;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import org.springframework.stereotype.Repository;

import java.util.Collection;
import java.util.List;
import java.util.Optional;

/**
 * Spring Data JPA repository for {@link Endpoint}.
 *
 * <p>The legacy enforces uniqueness on
 * {@code (PATH, METHOD, DESCRIPTION)}. The modern port keeps
 * that contract via a {@code @UniqueConstraint} on the
 * {@code ENDPOINT} table (see the Phase 2 SQL init script)
 * and uses a derived {@code exists} query for the friendly
 * pre-flight duplicate check in the service layer.
 */
@Repository
public interface EndpointRepository extends JpaRepository<Endpoint, Long> {

    boolean existsByPathAndMethodAndDescription(String path, String method, String description);

    Optional<Endpoint> findByPathAndMethodAndDescription(String path, String method, String description);

    /**
     * Endpoints bound (via {@code role_endpoint}) to any of the
     * given role names. Returns entities rather than a boolean —
     * {@code path} may contain Spring-style {@code {var}} segments,
     * which can't be pattern-matched against an incoming request
     * URI in SQL/JPQL; the caller (sso-admin's
     * {@code EndpointAccessService}) does that matching in Java
     * with {@code AntPathMatcher} over this small result set.
     */
    @Query("SELECT DISTINCT e FROM Endpoint e JOIN e.roles r WHERE r.name IN :roleNames")
    List<Endpoint> findByAnyRoleName(@Param("roleNames") Collection<String> roleNames);
}
