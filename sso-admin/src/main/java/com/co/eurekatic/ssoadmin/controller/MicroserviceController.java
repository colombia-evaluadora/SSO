package com.co.eurekatic.ssoadmin.controller;

import com.co.eurekatic.common.entity.Microservice;
import com.co.eurekatic.common.repository.MicroserviceRepository;
import com.co.eurekatic.ssoadmin.dto.ContainerStatusResponse;
import com.co.eurekatic.ssoadmin.dto.MicroserviceRequest;
import com.co.eurekatic.ssoadmin.dto.MicroserviceResponse;
import com.co.eurekatic.ssoadmin.dto.MicroserviceTestConnectionRequest;
import com.co.eurekatic.ssoadmin.dto.MicroserviceTestConnectionResponse;
import com.co.eurekatic.ssoadmin.exception.NotFoundException;
import com.co.eurekatic.ssoadmin.provisioner.ContainerProvisioner;
import com.co.eurekatic.ssoadmin.service.MicroserviceService;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

/**
 * Microservice CRUD + container operations proxy.
 *
 * <p>Path layout mirrors the legacy
 * {@code com.co.lowcode.sso.controller.MicroserviceController}
 * — endpoints are mounted under {@code /microservice} so the
 * gateway route {@code /sso-admin/microservice/**} lines up
 * with the legacy URLs.
 *
 * <p><b>Container operations</b> ({@code /container/**}) proxy
 * to the provisioner sidecar:
 * <ul>
 *   <li>{@code GET /{id}/container/status} — current state +
 *       startedAt (used by the admin-ui Query Services page).</li>
 *   <li>{@code GET /{id}/container/logs?tail=N} — last N
 *       lines of stdout+stderr.</li>
 *   <li>{@code POST /{id}/container/restart} — graceful
 *       restart; 404 when the container is gone.</li>
 * </ul>
 *
 * <p>Each container endpoint:
 * <ol>
 *   <li>Loads the {@code microservice} row by id.</li>
 *   <li>Refuses with 422 if the row is {@code kind=REST}
 *       (those have no container — the URL would be lying).</li>
 *   <li>Derives the full container name
 *       ({@code query-service-<instanceName> | <dialect>}).</li>
 *   <li>Delegates to {@link ContainerProvisioner}.</li>
 * </ol>
 *
 * <p>We don't add these methods to {@link MicroserviceService}
 * because the service is already large; the lookup-by-id +
 * kind-validation is two lines and keeping it inline in the
 * controller makes the proxy nature obvious to the next
 * reader.
 */
@RestController
@RequestMapping("/microservice")
public class MicroserviceController {

    private final MicroserviceService service;
    private final MicroserviceRepository repo;
    private final ContainerProvisioner provisioner;

    public MicroserviceController(MicroserviceService service,
                                  MicroserviceRepository repo,
                                  ContainerProvisioner provisioner) {
        this.service = service;
        this.repo = repo;
        this.provisioner = provisioner;
    }

    @PostMapping("/save")
    public ResponseEntity<MicroserviceResponse> create(@Valid @RequestBody MicroserviceRequest req) {
        return ResponseEntity.status(HttpStatus.CREATED).body(service.create(req));
    }

    /**
     * Sonda de conexión para el wizard "crear microservicio QUERY".
     * No persiste nada; abre una conexión con los parámetros dados
     * y devuelve éxito/fallo. Requiere rol ADMIN — la regla
     * {@code anyRequest().hasRole("ADMIN")} del {@code SecurityConfig}
     * ya cubre la ruta, sin necesidad de matchers explícitos.
     */
    @PostMapping("/testConnection")
    public MicroserviceTestConnectionResponse testConnection(
            @Valid @RequestBody MicroserviceTestConnectionRequest req) {
        return service.testConnection(req);
    }

    @PutMapping("/update")
    public MicroserviceResponse update(@Valid @RequestBody MicroserviceRequest req) {
        return service.update(req);
    }

    @GetMapping("/getMicroservices")
    public List<MicroserviceResponse> getAll() {
        return service.getAll();
    }

    @GetMapping("/getMicroservice")
    public MicroserviceResponse getByServiceId(@RequestParam String serviceId) {
        return service.getByServiceId(serviceId);
    }

    @GetMapping("/{id}")
    public MicroserviceResponse getById(@PathVariable Long id) {
        return service.getById(id);
    }

    @DeleteMapping("/{id}")
    public ResponseEntity<Void> delete(@PathVariable Long id) {
        service.delete(id);
        return ResponseEntity.noContent().build();
    }

    /* ====================== container ops (proxy to provisioner) ====================== */

    @GetMapping("/{id}/container/status")
    public ContainerStatusResponse containerStatus(@PathVariable Long id) {
        Microservice m = requireQueryRow(id);
        ContainerProvisioner.ContainerStatus s = provisioner.status(containerName(m));
        return new ContainerStatusResponse(
                s.state(),
                s.rawState(),
                s.containerId(),
                s.startedAt(),
                s.fullName());
    }

    @GetMapping(value = "/{id}/container/logs", produces = MediaType.TEXT_PLAIN_VALUE)
    public ResponseEntity<String> containerLogs(
            @PathVariable Long id,
            @RequestParam(defaultValue = "200") int tail) {
        Microservice m = requireQueryRow(id);
        String body = provisioner.logs(containerName(m), tail);
        return ResponseEntity.ok()
                .contentType(MediaType.TEXT_PLAIN)
                .body(body);
    }

    @PostMapping("/{id}/container/restart")
    public ResponseEntity<Void> containerRestart(@PathVariable Long id) {
        Microservice m = requireQueryRow(id);
        if (!provisioner.restart(containerName(m))) {
            // Container was already gone — surface as 404 so
            // admin-ui can offer a "recreate" action.
            throw new NotFoundException("Container for microservice", id);
        }
        return ResponseEntity.accepted().build();
    }

    /* ====================== internals ====================== */

    /**
     * Loads the row, 404s if missing, 422s if it's a REST row
     * (those have no container — the URL would be lying about
     * what the caller is asking for).
     */
    private Microservice requireQueryRow(Long id) {
        Microservice m = repo.findById(id)
                .orElseThrow(() -> new NotFoundException("Microservice", id));
        if (!"QUERY".equals(m.getKind())) {
            // We deliberately use 422 (Unprocessable Entity) —
            // the row exists, but the request makes no sense
            // for it. 400 (Bad Request) would imply the caller
            // could retry by changing the URL; 422 makes it
            // clear the row itself is the wrong kind.
            throw new IllegalArgumentException(
                    "Microservice " + id + " is kind=" + m.getKind()
                            + "; container ops require kind=QUERY");
        }
        return m;
    }

    /**
     * Derives the full container name from the row. Mirrors
     * the suffix logic in {@link MicroserviceService} so the
     * status/logs/restart endpoints talk to the same
     * container that {@code create} provisioned.
     */
    private static String containerName(Microservice m) {
        String suffix = m.getInstanceName() != null
                ? m.getInstanceName()
                : m.getDialect();
        return "query-service-" + suffix;
    }
}
