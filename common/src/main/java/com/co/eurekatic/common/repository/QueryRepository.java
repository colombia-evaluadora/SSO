package com.co.eurekatic.common.repository;

import com.co.eurekatic.common.entity.Query;
import org.springframework.data.jpa.repository.EntityGraph;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.QueryHints;
import org.springframework.stereotype.Repository;

import java.util.List;
import java.util.Optional;

import static org.hibernate.jpa.HibernateHints.HINT_FETCH_SIZE;

/**
 * Repository for {@link Query}. The catalog endpoints need the
 * query AND its bound roles in a single round-trip so the
 * authorization join (uuid + username via roles) can run; we
 * eagerly fetch the roles collection on every query method via
 * {@link EntityGraph}.
 *
 * <p>Without the eager fetch the per-row authorization check in
 * {@code QueryCatalogService} would either need to run inside a
 * session (fragile, defeats {@code @Transactional(readOnly=true)})
 * or trigger an N+1. The {@code @EntityGraph} collapses both
 * cases to a single SELECT + a JOIN.
 */
@Repository
public interface QueryRepository extends JpaRepository<Query, Long> {

    /**
     * Look up by the public {@code uuid} handle. Eagerly loads
     * {@code roles} so the catalog endpoint can decide permission
     * without an N+1 follow-up query. The unique index on
     * {@code UUID} keeps this O(1).
     */
    @EntityGraph(attributePaths = "roles")
    @QueryHints(@jakarta.persistence.QueryHint(name = HINT_FETCH_SIZE, value = "1"))
    Optional<Query> findByUuid(String uuid);

    boolean existsByUuid(String uuid);

    /**
     * All queries, id-ordered. Used by the catalog list endpoint
     * ({@code GET /myQueries}) when no instance filter is
     * supplied. The eager {@code roles} fetch keeps the
     * per-row authorization check inside the same transaction.
     */
    @EntityGraph(attributePaths = "roles")
    @QueryHints(@jakarta.persistence.QueryHint(name = HINT_FETCH_SIZE, value = "100"))
    List<Query> findAllByOrderByIdAsc();

    /**
     * All queries bound to the given microservice instance,
     * id-ordered. Powers the instance-grouped view of the
     * admin-ui Queries Catalog page. Backed by the
     * {@code idx_query_microservice} index so it stays O(log n)
     * as the catalog grows.
     */
    @EntityGraph(attributePaths = "roles")
    @QueryHints(@jakarta.persistence.QueryHint(name = HINT_FETCH_SIZE, value = "100"))
    List<Query> findAllByMicroservice_IdOrderByIdAsc(Long microserviceId);
}