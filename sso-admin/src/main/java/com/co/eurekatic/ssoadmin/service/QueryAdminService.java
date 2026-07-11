package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.common.entity.Microservice;
import com.co.eurekatic.common.entity.Query;
import com.co.eurekatic.common.entity.Role;
import com.co.eurekatic.common.repository.MicroserviceRepository;
import com.co.eurekatic.common.repository.QueryRepository;
import com.co.eurekatic.common.repository.RoleRepository;
import com.co.eurekatic.ssoadmin.dto.QueryRequest;
import com.co.eurekatic.ssoadmin.dto.QueryResponse;
import com.co.eurekatic.ssoadmin.exception.DuplicateException;
import com.co.eurekatic.ssoadmin.exception.NotFoundException;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/**
 * Query CRUD plus role bindings. Mirrors the shape of
 * {@link EndpointService} so the admin UI can use the same
 * patterns (list + create + update + delete + bind/unbind
 * role). The catalog endpoint on the read side (see
 * {@code QueryCatalogController}) is what {@code query-service}
 * calls — it does NOT go through this service.
 *
 * <p>Uniqueness: the legacy rule is {@code uuid}. We pre-check
 * with {@link QueryRepository#existsByUuid} for a friendlier
 * 409; the DB-level {@code UQ_QUERY_UUID} constraint is the
 * real source of truth under concurrent inserts.
 *
 * <p>Microservice binding: a non-null
 * {@link QueryRequest#microserviceId()} is resolved via
 * {@link MicroserviceRepository#findById} and the lookup MUST
 * yield a {@code kind=QUERY} row — REST rows have no container
 * to serve the SQL, so binding a query to one is a user error
 * we surface as 422 rather than letting the request pass and
 * hit a runtime failure on the first {@code /query} call.
 */
@Service
public class QueryAdminService {

    private final QueryRepository queryRepo;
    private final RoleRepository roleRepo;
    private final MicroserviceRepository microserviceRepo;

    public QueryAdminService(QueryRepository queryRepo,
                             RoleRepository roleRepo,
                             MicroserviceRepository microserviceRepo) {
        this.queryRepo = queryRepo;
        this.roleRepo = roleRepo;
        this.microserviceRepo = microserviceRepo;
    }

    @Transactional
    public QueryResponse create(QueryRequest req) {
        if (queryRepo.existsByUuid(req.uuid())) {
            throw new DuplicateException("Query", req.uuid());
        }
        Query q = new Query();
        copy(req, q);
        return QueryResponse.fromEntity(queryRepo.save(q));
    }

    @Transactional
    public QueryResponse update(QueryRequest req) {
        if (req.id() == null) {
            throw new IllegalArgumentException("id is required for update");
        }
        Query q = queryRepo.findById(req.id())
                .orElseThrow(() -> new NotFoundException("Query", req.id()));
        // Allow same uuid only for the same row.
        queryRepo.findByUuid(req.uuid()).ifPresent(existing -> {
            if (!existing.getId().equals(q.getId())) {
                throw new DuplicateException("Query", req.uuid());
            }
        });
        copy(req, q);
        return QueryResponse.fromEntity(queryRepo.save(q));
    }

    @Transactional(readOnly = true)
    public List<QueryResponse> getAll() {
        return queryRepo.findAll().stream()
                .map(QueryResponse::fromEntity)
                .toList();
    }

    @Transactional(readOnly = true)
    public QueryResponse getById(Long id) {
        return QueryResponse.fromEntity(queryRepo.findById(id)
                .orElseThrow(() -> new NotFoundException("Query", id)));
    }

    @Transactional
    public void delete(Long id) {
        if (!queryRepo.existsById(id)) {
            throw new NotFoundException("Query", id);
        }
        queryRepo.deleteById(id);
    }

    /* ====================== bindings: role ====================== */

    @Transactional
    public void bindRole(Long queryId, Long roleId) {
        Query q = queryRepo.findById(queryId)
                .orElseThrow(() -> new NotFoundException("Query", queryId));
        Role r = roleRepo.findById(roleId)
                .orElseThrow(() -> new NotFoundException("Role", roleId));
        q.addRole(r);
    }

    @Transactional
    public void unbindRole(Long queryId, Long roleId) {
        Query q = queryRepo.findById(queryId)
                .orElseThrow(() -> new NotFoundException("Query", queryId));
        Role r = roleRepo.findById(roleId)
                .orElseThrow(() -> new NotFoundException("Role", roleId));
        q.removeRole(r);
    }

    /**
     * Compact DTO matching the {@code EndpointService.RoleChecked}
     * shape: id plus a flag telling the admin UI whether the
     * role is currently bound to the query. The field names use
     * the suffixed convention ({@code roleId} + {@code checked})
     * to match the rest of the module — see AppService, the
     * admin-ui QueryRoleChecked type, and the
     * {@code admin-ui/scripts/smoke-query-roles.sh} contract.
     *
     * <p>An earlier draft used bare {@code id} and {@code bound};
     * the admin-ui binding tab was silently rendering
     * {@code data-testid="role-toggle-undefined"} and firing
     * {@code POST /query/{id}/role/undefined} because the JSON
     * parser read {@code row.roleId} as undefined.
     */
    public record RoleChecked(Long roleId, String name, boolean checked) {}

    @Transactional(readOnly = true)
    public List<RoleChecked> getRolesForQueryChecked(Long queryId) {
        Query q = queryRepo.findById(queryId)
                .orElseThrow(() -> new NotFoundException("Query", queryId));
        Set<Long> bound = q.getRoles().stream()
                .map(Role::getId)
                .collect(java.util.stream.Collectors.toCollection(LinkedHashSet::new));
        return roleRepo.findAll().stream()
                .map(r -> new RoleChecked(r.getId(), r.getName(), bound.contains(r.getId())))
                .toList();
    }

    /* ====================== helpers ====================== */

    private void copy(QueryRequest req, Query q) {
        q.setUuid(req.uuid());
        q.setQuery(req.query());
        q.setType(req.type());
        q.setPublicEnd(req.publicEnd());
        q.setCaptcha(req.captcha());
        q.setDetail(req.detail());
        q.setAction(req.action());
        q.setStyle(req.style());
        // Resolve microservice binding. Null clears the
        // association (back to "global" — any instance may
        // serve). A non-null id MUST resolve to a kind=QUERY
        // row; binding a query to a REST row is meaningless
        // because there is no container to execute the SQL.
        // We throw 422 (Unprocessable) rather than 400 because
        // the request itself is well-formed; the referenced
        // entity is just wrong.
        q.setMicroservice(resolveQueryMicroservice(req.microserviceId()));
    }

    /**
     * Looks up the microservice referenced by the request,
     * enforcing {@code kind=QUERY}. Returns {@code null} when
     * the request passed {@code null} (clear binding / global).
     *
     * @throws IllegalArgumentException if the id is non-null
     *         but does not exist, OR the row exists but is
     *         not a QUERY kind. Both map to 422 INVALID_REQUEST.
     */
    private Microservice resolveQueryMicroservice(Long microserviceId) {
        if (microserviceId == null) return null;
        Microservice m = microserviceRepo.findById(microserviceId)
                .orElseThrow(() -> new IllegalArgumentException(
                        "microserviceId " + microserviceId + " no existe"));
        if (!"QUERY".equals(m.getKind())) {
            throw new IllegalArgumentException(
                    "microserviceId " + microserviceId
                            + " es kind=" + m.getKind()
                            + "; los queries solo se vinculan a kind=QUERY");
        }
        return m;
    }
}
