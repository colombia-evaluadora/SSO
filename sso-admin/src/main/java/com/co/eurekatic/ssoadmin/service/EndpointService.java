package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.common.entity.Endpoint;
import com.co.eurekatic.common.entity.Microservice;
import com.co.eurekatic.common.entity.Role;
import com.co.eurekatic.common.repository.EndpointRepository;
import com.co.eurekatic.common.repository.MicroserviceRepository;
import com.co.eurekatic.common.repository.RoleRepository;
import com.co.eurekatic.ssoadmin.dto.EndpointRequest;
import com.co.eurekatic.ssoadmin.dto.EndpointResponse;
import com.co.eurekatic.ssoadmin.exception.DuplicateException;
import com.co.eurekatic.ssoadmin.exception.NotFoundException;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;

/**
 * Endpoint CRUD plus microservice and role bindings. The
 * legacy bundled endpoint/route management in
 * {@code com.co.lowcode.sso.service.EndpointService}; in the
 * modern port the two stay separate (the join tables are
 * independent) but follow the same shape.
 *
 * <p>Uniqueness: the legacy rule is
 * (PATH, METHOD, DESCRIPTION). We pre-check with
 * {@link EndpointRepository#existsByPathAndMethodAndDescription}
 * for a friendlier 409, but the DB-level
 * {@code uq_endpoint_path_method_desc} constraint is the
 * real source of truth under concurrent inserts.
 */
@Service
public class EndpointService {

    private final EndpointRepository endpointRepo;
    private final MicroserviceRepository microserviceRepo;
    private final RoleRepository roleRepo;

    public EndpointService(EndpointRepository endpointRepo,
                           MicroserviceRepository microserviceRepo,
                           RoleRepository roleRepo) {
        this.endpointRepo = endpointRepo;
        this.microserviceRepo = microserviceRepo;
        this.roleRepo = roleRepo;
    }

    @Transactional
    public EndpointResponse create(EndpointRequest req) {
        if (endpointRepo.existsByPathAndMethodAndDescription(
                req.path(), req.method(), req.description())) {
            throw new DuplicateException("Endpoint",
                    req.method() + " " + req.path() + " (" + req.description() + ")");
        }
        Endpoint e = new Endpoint();
        copy(req, e);
        return EndpointResponse.fromEntity(endpointRepo.save(e));
    }

    @Transactional
    public EndpointResponse update(EndpointRequest req) {
        if (req.id() == null) {
            throw new IllegalArgumentException("id is required for update");
        }
        Endpoint e = endpointRepo.findById(req.id())
                .orElseThrow(() -> new NotFoundException("Endpoint", req.id()));
        // Allow same (path, method, description) only for the same row.
        endpointRepo.findByPathAndMethodAndDescription(
                        req.path(), req.method(), req.description())
                .ifPresent(existing -> {
                    if (!existing.getId().equals(e.getId())) {
                        throw new DuplicateException("Endpoint",
                                req.method() + " " + req.path() + " (" + req.description() + ")");
                    }
                });
        copy(req, e);
        return EndpointResponse.fromEntity(endpointRepo.save(e));
    }

    @Transactional(readOnly = true)
    public List<EndpointResponse> getAll() {
        return endpointRepo.findAll().stream()
                .map(EndpointResponse::fromEntity)
                .toList();
    }

    @Transactional(readOnly = true)
    public EndpointResponse getById(Long id) {
        Endpoint e = endpointRepo.findById(id)
                .orElseThrow(() -> new NotFoundException("Endpoint", id));
        return EndpointResponse.fromEntity(e);
    }

    @Transactional
    public void delete(Long id) {
        if (!endpointRepo.existsById(id)) {
            throw new NotFoundException("Endpoint", id);
        }
        endpointRepo.deleteById(id);
    }

    /* ====================== bindings: microservice ====================== */

    @Transactional
    public void bindMicroservice(Long endpointId, Long microserviceId) {
        Endpoint e = endpointRepo.findById(endpointId)
                .orElseThrow(() -> new NotFoundException("Endpoint", endpointId));
        Microservice m = microserviceRepo.findById(microserviceId)
                .orElseThrow(() -> new NotFoundException("Microservice", microserviceId));
        e.addMicroservice(m);
        endpointRepo.save(e);
    }

    @Transactional
    public void unbindMicroservice(Long endpointId, Long microserviceId) {
        Endpoint e = endpointRepo.findById(endpointId)
                .orElseThrow(() -> new NotFoundException("Endpoint", endpointId));
        Microservice m = microserviceRepo.findById(microserviceId)
                .orElseThrow(() -> new NotFoundException("Microservice", microserviceId));
        e.removeMicroservice(m);
        endpointRepo.save(e);
    }

    /* ====================== bindings: role ====================== */

    @Transactional
    public void bindRole(Long endpointId, Long roleId) {
        Endpoint e = endpointRepo.findById(endpointId)
                .orElseThrow(() -> new NotFoundException("Endpoint", endpointId));
        Role r = roleRepo.findById(roleId)
                .orElseThrow(() -> new NotFoundException("Role", roleId));
        e.addRole(r);
        endpointRepo.save(e);
    }

    @Transactional
    public void unbindRole(Long endpointId, Long roleId) {
        Endpoint e = endpointRepo.findById(endpointId)
                .orElseThrow(() -> new NotFoundException("Endpoint", endpointId));
        Role r = roleRepo.findById(roleId)
                .orElseThrow(() -> new NotFoundException("Role", roleId));
        e.removeRole(r);
        endpointRepo.save(e);
    }

    /* ====================== "checked" listings ====================== */

    /**
     * All roles with a {@code checked} flag — drives the
     * multi-select UI for editing which roles can invoke this
     * endpoint.
     */
    @Transactional(readOnly = true)
    public List<RoleChecked> getRolesForEndpointChecked(Long endpointId) {
        Endpoint e = endpointRepo.findById(endpointId)
                .orElseThrow(() -> new NotFoundException("Endpoint", endpointId));
        Set<Long> bound = e.getRoles().stream()
                .map(Role::getId)
                .collect(Collectors.toCollection(LinkedHashSet::new));
        return roleRepo.findAll().stream()
                .map(r -> new RoleChecked(r.getId(), r.getName(), bound.contains(r.getId())))
                .toList();
    }

    /**
     * All microservices with a {@code checked} flag — drives
     * the multi-select UI for editing which microservices
     * expose this endpoint.
     */
    @Transactional(readOnly = true)
    public List<MicroserviceChecked> getMicroservicesForEndpointChecked(Long endpointId) {
        Endpoint e = endpointRepo.findById(endpointId)
                .orElseThrow(() -> new NotFoundException("Endpoint", endpointId));
        Set<Long> bound = e.getMicroservices().stream()
                .map(Microservice::getId)
                .collect(Collectors.toCollection(LinkedHashSet::new));
        return microserviceRepo.findAll().stream()
                .map(m -> new MicroserviceChecked(m.getId(), m.getServiceId(), bound.contains(m.getId())))
                .toList();
    }

    /* ------------- internals ------------- */

    private static void copy(EndpointRequest req, Endpoint e) {
        e.setMethod(req.method());
        e.setPath(req.path());
        e.setDescription(req.description());
        e.setNumberParams(req.numberParams() == null ? 0 : req.numberParams());
    }

    public record RoleChecked(Long roleId, String name, boolean checked) {}

    public record MicroserviceChecked(Long microserviceId, String serviceId, boolean checked) {}
}
