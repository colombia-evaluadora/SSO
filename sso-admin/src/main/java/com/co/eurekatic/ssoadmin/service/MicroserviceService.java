package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.common.entity.App;
import com.co.eurekatic.common.entity.Microservice;
import com.co.eurekatic.common.repository.AppRepository;
import com.co.eurekatic.common.repository.MicroserviceRepository;
import com.co.eurekatic.ssoadmin.dto.MicroserviceRequest;
import com.co.eurekatic.ssoadmin.dto.MicroserviceResponse;
import com.co.eurekatic.ssoadmin.dto.MicroserviceTestConnectionRequest;
import com.co.eurekatic.ssoadmin.dto.MicroserviceTestConnectionResponse;
import com.co.eurekatic.ssoadmin.exception.DuplicateException;
import com.co.eurekatic.ssoadmin.exception.NotFoundException;
import com.co.eurekatic.ssoadmin.provisioner.ContainerProvisioner;
import com.co.eurekatic.ssoadmin.provisioner.EurekaReadinessProbe;
import com.co.eurekatic.ssoadmin.provisioner.ProvisioningException;
import com.co.eurekatic.ssoadmin.provisioner.ProvisionSpec;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.List;

/**
 * Microservice CRUD. The legacy
 * {@code com.co.lowcode.sso.service.MicroserviceService} also
 * exposed an {@code endpoint/checked} listing and a binding
 * helper; those concerns live on {@link EndpointService} in
 * the modern port (the join table is owned by Endpoint).
 *
 * <p><b>Provisioning.</b> For rows with
 * {@link MicroserviceRequest#kind() kind=QUERY} this service
 * drives the dynamic query-service container lifecycle:
 * <ol>
 *   <li>{@link #create(MicroserviceRequest)} persists the row
 *       first, then calls {@link ContainerProvisioner#provision(ProvisionSpec)}
 *       (which translates the spec into a
 *       {@code POST /v1.43/containers/create} against the Docker
 *       daemon via the provisioner sidecar).</li>
 *   <li>Once the container is up, {@link EurekaReadinessProbe#waitForInstance(String)}
 *       polls the local {@code DiscoveryClient} until the new
 *       instance appears under the expected service-id
 *       ({@code query-service-<instanceName>} or
 *       {@code query-service-<dialect>}). Only then does
 *       {@code create} return — the gateway can route traffic
 *       to the new container by the time the call completes.</li>
 *   <li>{@link #delete(Long)} reverses the flow best-effort:
 *       the row is dropped even if the provisioner is
 *       unreachable (logged as WARN), so admin-ui never gets
 *       stuck retrying a delete that the user has already
 *       confirmed.</li>
 * </ol>
 *
 * <p>REST rows take no provisioner path — the
 * {@code ContainerProvisioner} bean is only invoked when
 * {@code "QUERY".equals(req.kind())}.
 */
@Service
public class MicroserviceService {

    private static final Logger log = LoggerFactory.getLogger(MicroserviceService.class);

    private final MicroserviceRepository repo;
    private final AppRepository appRepo;
    private final ContainerProvisioner provisioner;
    private final EurekaReadinessProbe readinessProbe;

    public MicroserviceService(MicroserviceRepository repo,
                               AppRepository appRepo,
                               ContainerProvisioner provisioner,
                               EurekaReadinessProbe readinessProbe) {
        this.repo = repo;
        this.appRepo = appRepo;
        this.provisioner = provisioner;
        this.readinessProbe = readinessProbe;
    }

    /**
     * Persist + provision for {@code kind=QUERY} rows.
     *
     * <p><b>Why not {@code @Transactional}:</b> the provisioning
     * chain ({@code provisioner} + {@code readinessProbe}) can
     * fail in ways unrelated to the DB row — most commonly an
     * {@code EUREKA_TIMEOUT} from {@link EurekaReadinessProbe}
     * when a fresh container takes longer than 45s to register.
     * A surrounding transaction would treat that as a reason to
     * discard the persisted row, leaving a {@code query-service-*}
     * container running on the host with no DB record ("ghost
     * container"). {@code Spring Data}'s
     * {@code SimpleJpaRepository.save(...)} is itself annotated
     * {@code @Transactional}, so removing the surrounding tx is
     * safe — the INSERT commits as soon as {@code save()} returns.
     *
     * <p>The provisioning steps are best-effort: any
     * {@link ProvisioningException} is logged at WARN and the
     * call still returns the persisted row. Admin-ui can check
     * container reachability via the existing
     * {@code GET /microservice/{id}/container/status} endpoint
     * and re-attempt provisioning manually if needed.
     */
    public MicroserviceResponse create(MicroserviceRequest req) {
        if (repo.existsByServiceId(req.serviceId())) {
            throw new DuplicateException("Microservice", req.serviceId());
        }

        // Default the kind discriminator if the client omitted it
        // (REST is the legacy behavior).
        String kind = (req.kind() == null || req.kind().isBlank()) ? "REST" : req.kind();
        if (!"REST".equals(kind) && !"QUERY".equals(kind)) {
            throw new IllegalArgumentException("kind must be REST or QUERY, got: " + kind);
        }

        // Cross-field validation for QUERY rows. Bean Validation
        // doesn't compose well across fields; doing it here keeps
        // the DTO annotation list flat.
        if ("QUERY".equals(kind)) {
            requireQueryField(req.dialect(), "dialect");
            requireQueryField(req.jdbcUrl(), "jdbcUrl");
            requireQueryField(req.dbUsername(), "dbUsername");
            if (req.instanceName() != null
                    && repo.existsByInstanceName(req.instanceName())) {
                throw new DuplicateException("Microservice.instanceName",
                        req.instanceName());
            }
        }

        Microservice m = new Microservice();
        copy(req, m);
        m.setKind(kind);
        // save() commits in its own @Transactional (Spring Data
        // JPA). Even if the QUERY provisioning below throws and
        // is caught, this row stays.
        Microservice saved = repo.save(m);
        log.info("Persisted microservice id={} serviceId={} kind={}",
                saved.getId(), saved.getServiceId(), saved.getKind());

        if ("QUERY".equals(kind)) {
            provisionQueryBestEffort(req, saved);
        }

        return MicroserviceResponse.fromEntity(saved);
    }

    /**
     * Best-effort provisioning for a freshly persisted QUERY
     * row. Any {@link ProvisioningException} is caught and
     * logged at WARN — the call site has already committed the
     * DB row and should return success regardless. If the
     * container later shows up in
     * {@link ContainerProvisioner#status(String) status}, the
     * admin sees it. If it never shows up, the admin can delete
     * the row (which best-effort deprovisions the container
     * too) and try again.
     */
    private void provisionQueryBestEffort(MicroserviceRequest req, Microservice saved) {
        String instanceId = req.instanceName() != null
                ? req.instanceName()
                : req.dialect();
        try {
            provisioner.provision(new ProvisionSpec(
                    instanceId,
                    req.dialect(),
                    req.jdbcUrl(),
                    req.dbUsername(),
                    req.dbPassword(),
                    req.poolSize() != null ? req.poolSize() : 10));
            readinessProbe.waitForInstance("query-service-" + instanceId);
            log.info("Provisioned query-service instance {} (dialect={})",
                    instanceId, req.dialect());
        } catch (ProvisioningException pe) {
            // Row stays. The container may or may not be running
            // (depends on which step failed); the admin can
            // check via /container/{id}/status and either wait
            // it out or delete-and-retry.
            log.warn("Row id={} was persisted but provisioning failed "
                            + "(code={}, message={}); container '{}' may be left "
                            + "running on the host. Admin can retry via delete+create.",
                    saved.getId(), pe.getCode(), pe.getMessage(),
                    "query-service-" + instanceId);
        }
    }

    @Transactional
    public MicroserviceResponse update(MicroserviceRequest req) {
        if (req.id() == null) {
            throw new IllegalArgumentException("id is required for update");
        }
        Microservice m = repo.findById(req.id())
                .orElseThrow(() -> new NotFoundException("Microservice", req.id()));
        copy(req, m);
        return MicroserviceResponse.fromEntity(repo.save(m));
    }

    @Transactional(readOnly = true)
    public List<MicroserviceResponse> getAll() {
        return repo.findAll().stream()
                .map(MicroserviceResponse::fromEntity)
                .toList();
    }

    @Transactional(readOnly = true)
    public MicroserviceResponse getById(Long id) {
        Microservice m = repo.findById(id)
                .orElseThrow(() -> new NotFoundException("Microservice", id));
        return MicroserviceResponse.fromEntity(m);
    }

    @Transactional(readOnly = true)
    public MicroserviceResponse getByServiceId(String serviceId) {
        Microservice m = repo.findByServiceId(serviceId)
                .orElseThrow(() -> new NotFoundException("Microservice", serviceId));
        return MicroserviceResponse.fromEntity(m);
    }

    @Transactional
    public void delete(Long id) {
        Microservice m = repo.findById(id)
                .orElseThrow(() -> new NotFoundException("Microservice", id));

        // Best-effort: drop the row even if deprovisioning
        // blows up — leaving an orphan row on disk is worse
        // than leaving an orphan container, because the user
        // can't recover from the row state without manual SQL.
        if ("QUERY".equals(m.getKind())) {
            String instanceId = m.getInstanceName() != null
                    ? m.getInstanceName()
                    : m.getDialect();
            try {
                provisioner.deprovision("query-service-" + instanceId);
                log.info("Deprovisioned query-service instance {}", instanceId);
            } catch (RuntimeException ex) {
                log.warn("Deprovision failed for instance {}; row will still be removed: {}",
                        instanceId, ex.getMessage());
            }
        }

        repo.delete(m);
    }

    /* ------------- internals ------------- */

    private void copy(MicroserviceRequest req, Microservice m) {
        m.setServiceId(req.serviceId());
        m.setDescription(req.description());
        m.setRequestUri(req.requestUri());
        m.setTargetUriPath(req.targetUriPath());
        m.setTargetUrlHost(req.targetUrlHost());
        m.setTargetUrlPort(req.targetUrlPort());
        // QUERY-only fields. REST rows leave these null — the
        // DB defaults for KIND keep the discriminator sane even
        // when the client never sent one.
        m.setDialect(req.dialect());
        m.setJdbcUrl(req.jdbcUrl());
        m.setDbUsername(req.dbUsername());
        m.setDbPassword(req.dbPassword());
        m.setPoolSize(req.poolSize());
        m.setInstanceName(req.instanceName());
        // Optional primary-app FK. Same rationale as
        // RouteService.resolveRouteApp: null clears, non-null
        // must resolve to an existing app.
        m.setApp(resolveMicroserviceApp(req.appId()));
    }

    private App resolveMicroserviceApp(Long appId) {
        if (appId == null) return null;
        return appRepo.findById(appId)
                .orElseThrow(() -> new IllegalArgumentException(
                        "appId " + appId + " no existe"));
    }

    private static void requireQueryField(String value, String name) {
        if (value == null || value.isBlank()) {
            throw new IllegalArgumentException(
                    name + " is required when kind=QUERY");
        }
    }

    /**
     * Sonda sin persistencia: abre una conexión con los parámetros
     * JDBC dados y ejecuta {@link Connection#isValid(int)} con un
     * timeout de 5s. Dialect-agnostic — el driver decide cómo
     * validar (Postgres hace una consulta vacía interna; Oracle /
     * SQLServer hacen equivalente). No se ejecuta SQL arbitrario:
     * la sonda es del driver, no del usuario.
     *
     * <p>Por qué {@link DriverManager} y no un {@code DataSource}
     * temporal: para una validación one-shot abrir/cerrar sin pool
     * es más simple. No se necesitan conexiones concurrentes y el
     * classpath runtime ya incluye el driver (Postgres al menos;
     * otros dialectos se cargan vía SPI del JDK si están en el
     * classpath del container).
     *
     * <p>En éxito devuelve el record con la latencia en ms. En
     * fallo lanza {@link IllegalArgumentException}, que el
     * {@code GlobalExceptionHandler} mapea a 400
     * {@code INVALID_REQUEST} con cuerpo
     * {@code {code, message, timestamp}}.
     */
    public MicroserviceTestConnectionResponse testConnection(MicroserviceTestConnectionRequest req) {
        if (req.jdbcUrl() == null || !req.jdbcUrl().startsWith("jdbc:")) {
            throw new IllegalArgumentException("jdbcUrl debe comenzar con 'jdbc:'");
        }
        long t0 = System.nanoTime();
        try (Connection c = DriverManager.getConnection(
                req.jdbcUrl(),
                req.dbUsername(),
                req.dbPassword() == null ? "" : req.dbPassword())) {
            if (!c.isValid(5)) {
                throw new IllegalArgumentException(
                        "La conexión se abrió pero el driver reportó inválida (timeout 5s)");
            }
            long ms = (System.nanoTime() - t0) / 1_000_000L;
            return MicroserviceTestConnectionResponse.success(req.dialect(), ms);
        } catch (SQLException e) {
            // Mensaje sanitizado: NO incluye la URL completa (puede
            // llevar credenciales embebidas vía ?user=...&password=...)
            // ni el password. El driver ya da un mensaje razonablemente
            // útil (e.g. "FATAL: password authentication failed for
            // user \"x\"").
            throw new IllegalArgumentException(
                    "No se pudo conectar: " + sanitize(e.getMessage()));
        }
    }

    /**
     * Recorta el mensaje del driver a una sola línea y a 240
     * caracteres. Protege la UI de payloads enormes (algunos
     * drivers apilan stack traces multi-línea) y mantiene
     * uniforme la longitud del toast/banner.
     */
    private static String sanitize(String msg) {
        if (msg == null) return "error desconocido del driver";
        int nl = msg.indexOf('\n');
        if (nl > 0) msg = msg.substring(0, nl);
        return msg.length() > 240 ? msg.substring(0, 240) + "…" : msg;
    }
}
