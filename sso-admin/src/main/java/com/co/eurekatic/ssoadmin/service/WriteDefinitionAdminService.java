package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.common.entity.Microservice;
import com.co.eurekatic.common.entity.Role;
import com.co.eurekatic.common.entity.WriteDefinition;
import com.co.eurekatic.common.repository.MicroserviceRepository;
import com.co.eurekatic.common.repository.RoleRepository;
import com.co.eurekatic.common.repository.WriteDefinitionRepository;
import com.co.eurekatic.ssoadmin.dto.WriteDefinitionRequest;
import com.co.eurekatic.ssoadmin.dto.WriteDefinitionResponse;
import com.co.eurekatic.ssoadmin.exception.DuplicateException;
import com.co.eurekatic.ssoadmin.exception.NotFoundException;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/**
 * WriteDefinition CRUD plus role bindings. Same shape as
 * {@link QueryAdminService} — see that class for the rationale
 * on uniqueness pre-check and DB-level constraint.
 *
 * <p>This service is the ADMIN surface (manage the catalog).
 * The catalog endpoint that {@code query-service} consumes is
 * a separate read-side class ({@code QueryCatalogController} /
 * {@code WriteCatalogController}) that performs the username
 * authorization check against the {@code ROLE_WRITE} join.
 *
 * <p>Microservice binding: a non-null
 * {@link WriteDefinitionRequest#microserviceId()} is resolved
 * via {@link MicroserviceRepository#findById} and the lookup
 * MUST yield a {@code kind=QUERY} row — REST rows have no
 * container to receive the write, so binding a write to one is
 * a user error we surface as 400 INVALID_REQUEST (via
 * {@code GlobalExceptionHandler}'s
 * {@code IllegalArgumentException} mapper) rather than letting
 * the request pass and hit a runtime failure on the first
 * {@code /write} call.
 */
@Service
public class WriteDefinitionAdminService {

    private final WriteDefinitionRepository writeRepo;
    private final RoleRepository roleRepo;
    private final MicroserviceRepository microserviceRepo;

    public WriteDefinitionAdminService(WriteDefinitionRepository writeRepo,
                                       RoleRepository roleRepo,
                                       MicroserviceRepository microserviceRepo) {
        this.writeRepo = writeRepo;
        this.roleRepo = roleRepo;
        this.microserviceRepo = microserviceRepo;
    }

    @Transactional
    public WriteDefinitionResponse create(WriteDefinitionRequest req) {
        if (writeRepo.existsByUuid(req.uuid())) {
            throw new DuplicateException("WriteDefinition", req.uuid());
        }
        WriteDefinition w = new WriteDefinition();
        copy(req, w);
        return WriteDefinitionResponse.fromEntity(writeRepo.save(w));
    }

    @Transactional
    public WriteDefinitionResponse update(WriteDefinitionRequest req) {
        if (req.id() == null) {
            throw new IllegalArgumentException("id is required for update");
        }
        WriteDefinition w = writeRepo.findById(req.id())
                .orElseThrow(() -> new NotFoundException("WriteDefinition", req.id()));
        writeRepo.findByUuid(req.uuid()).ifPresent(existing -> {
            if (!existing.getId().equals(w.getId())) {
                throw new DuplicateException("WriteDefinition", req.uuid());
            }
        });
        copy(req, w);
        return WriteDefinitionResponse.fromEntity(writeRepo.save(w));
    }

    @Transactional(readOnly = true)
    public List<WriteDefinitionResponse> getAll() {
        return writeRepo.findAll().stream()
                .map(WriteDefinitionResponse::fromEntity)
                .toList();
    }

    @Transactional(readOnly = true)
    public WriteDefinitionResponse getById(Long id) {
        return WriteDefinitionResponse.fromEntity(writeRepo.findById(id)
                .orElseThrow(() -> new NotFoundException("WriteDefinition", id)));
    }

    @Transactional
    public void delete(Long id) {
        if (!writeRepo.existsById(id)) {
            throw new NotFoundException("WriteDefinition", id);
        }
        writeRepo.deleteById(id);
    }

    /* ====================== bindings: role ====================== */

    @Transactional
    public void bindRole(Long writeId, Long roleId) {
        WriteDefinition w = writeRepo.findById(writeId)
                .orElseThrow(() -> new NotFoundException("WriteDefinition", writeId));
        Role r = roleRepo.findById(roleId)
                .orElseThrow(() -> new NotFoundException("Role", roleId));
        w.addRole(r);
    }

    @Transactional
    public void unbindRole(Long writeId, Long roleId) {
        WriteDefinition w = writeRepo.findById(writeId)
                .orElseThrow(() -> new NotFoundException("WriteDefinition", writeId));
        Role r = roleRepo.findById(roleId)
                .orElseThrow(() -> new NotFoundException("Role", roleId));
        w.removeRole(r);
    }

    /**
     * Compact DTO matching the {@code EndpointService.RoleChecked}
     * shape: id plus a flag telling the admin UI whether the
     * role is currently bound to the write. The field names use
     * the suffixed convention ({@code roleId} + {@code checked})
     * to match the rest of the module — see AppService,
     * QueryAdminService, and the
     * {@code admin-ui/scripts/smoke-write-roles.sh} contract.
     *
     * <p>Note: there is currently no admin-ui consumer for
     * write-definition bindings (no page renders this endpoint
     * yet). The fix is preventive — when that page is built,
     * it will follow the same {@code roleId} + {@code checked}
     * convention as the other entities, and this smoke
     * guarantees the contract holds.
     */
    public record RoleChecked(Long roleId, String name, boolean checked) {}

    @Transactional(readOnly = true)
    public List<RoleChecked> getRolesForWriteChecked(Long writeId) {
        WriteDefinition w = writeRepo.findById(writeId)
                .orElseThrow(() -> new NotFoundException("WriteDefinition", writeId));
        Set<Long> bound = w.getRoles().stream()
                .map(Role::getId)
                .collect(java.util.stream.Collectors.toCollection(LinkedHashSet::new));
        return roleRepo.findAll().stream()
                .map(r -> new RoleChecked(r.getId(), r.getName(), bound.contains(r.getId())))
                .toList();
    }

    /* ====================== helpers ====================== */

    private void copy(WriteDefinitionRequest req, WriteDefinition w) {
        w.setUuid(req.uuid());
        w.setWriteType(req.writeType());
        w.setTableName(req.tableName());
        w.setColumns(req.columns());
        w.setKeyColumns(req.keyColumns());
        // Resolve microservice binding. Null clears the
        // association (back to "global" — any instance may
        // serve). A non-null id MUST resolve to a kind=QUERY
        // row; binding a write to a REST row is meaningless
        // because there is no container to execute the SQL.
        // The IllegalArgumentException → 400 INVALID_REQUEST
        // mapping is owned by GlobalExceptionHandler.
        w.setMicroservice(resolveWriteMicroservice(req.microserviceId()));
    }

    /**
     * Looks up the microservice referenced by the request,
     * enforcing {@code kind=QUERY}. Returns {@code null} when
     * the request passed {@code null} (clear binding / global).
     *
     * @throws IllegalArgumentException if the id is non-null
     *         but does not exist, OR the row exists but is not
     *         a QUERY kind. Both map to 400 INVALID_REQUEST via
     *         {@code GlobalExceptionHandler}.
     */
    private Microservice resolveWriteMicroservice(Long microserviceId) {
        if (microserviceId == null) return null;
        Microservice m = microserviceRepo.findById(microserviceId)
                .orElseThrow(() -> new IllegalArgumentException(
                        "microserviceId " + microserviceId + " no existe"));
        if (!"QUERY".equals(m.getKind())) {
            throw new IllegalArgumentException(
                    "microserviceId " + microserviceId
                            + " es kind=" + m.getKind()
                            + "; los writes solo se vinculan a kind=QUERY");
        }
        return m;
    }
}
