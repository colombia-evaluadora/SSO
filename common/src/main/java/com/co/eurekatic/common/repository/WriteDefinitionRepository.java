package com.co.eurekatic.common.repository;

import com.co.eurekatic.common.entity.WriteDefinition;
import org.springframework.data.jpa.repository.EntityGraph;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

import java.util.Optional;

/**
 * Repository for {@link WriteDefinition}. Same eager-roles
 * pattern as {@link QueryRepository} so the catalog endpoint
 * can authorize in one round-trip.
 */
@Repository
public interface WriteDefinitionRepository extends JpaRepository<WriteDefinition, Long> {

    /**
     * Look up by the public {@code uuid} handle. Eagerly loads
     * {@code roles} for the authorization check. Unique index
     * on {@code UUID} keeps this O(1).
     */
    @EntityGraph(attributePaths = "roles")
    Optional<WriteDefinition> findByUuid(String uuid);

    boolean existsByUuid(String uuid);
}
