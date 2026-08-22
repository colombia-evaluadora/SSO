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
    private final JdbcConnectionProbe connectionProbe;

    public MicroserviceService(MicroserviceRepository repo,
                               AppRepository appRepo,
                               ContainerProvisioner provisioner,
                               EurekaReadinessProbe readinessProbe,
                               JdbcConnectionProbe connectionProbe) {
        this.repo = repo;
        this.appRepo = appRepo;
        this.provisioner = provisioner;
        this.readinessProbe = readinessProbe;
        this.connectionProbe = connectionProbe;
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
            throw new IllegalArgumentException("kind debe ser REST o QUERY, se recibió: " + kind);
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
            // Gate de conexión: no se persiste ni se provisiona un
            // query-service que no puede hablar con su base de datos.
            // testConnection lanza IllegalArgumentException -> 400
            // INVALID_REQUEST, así que el fallo llega a la UI con el
            // mensaje del driver ya sanitizado y sin fila huérfana ni
            // contenedor levantado.
            testConnection(new MicroserviceTestConnectionRequest(
                    req.jdbcUrl(),
                    req.dbUsername(),
                    req.dbPassword(),
                    req.dialect()));
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

    /**
     * Recrea el contenedor de una fila {@code kind=QUERY}: borra
     * el contenedor existente (si lo hay) y levanta uno nuevo con
     * la MISMA spec persistida en la fila, a partir de la imagen
     * que el provisioner tenga configurada AHORA.
     *
     * <p>Por qué hace falta un endpoint aparte de {@code restart}:
     * {@code POST /container/restart} es {@code docker restart}
     * sobre el MISMO contenedor — reutiliza el filesystem que ya
     * tenía al crearse, así que aunque se reconstruya y se
     * redespliegue la imagen {@code query-service} (mismo tag,
     * contenido nuevo — el caso típico de {@code docker compose
     * build && up -d} en un entorno de test), el contenedor sigue
     * corriendo el código VIEJO hasta que alguien lo borre y lo
     * vuelva a crear. Esta operación hace justo eso: {@code
     * deprovision} + {@code provision} con el mismo spec, así que
     * el contenedor que queda arriba corre la imagen actual.
     *
     * <p>No es best-effort como {@link #create}: quien llama a
     * esto es un admin pidiendo explícitamente "recrea este
     * contenedor ahora" — si falla, tiene que enterarse (el
     * controller deja que {@link ProvisioningException} se
     * propague al {@code GlobalExceptionHandler}, que la mapea al
     * status HTTP correspondiente), no quedarse pensando que
     * funcionó cuando el contenedor real puede haber quedado
     * abajo a mitad del ciclo borrar+crear.
     *
     * @throws NotFoundException si la fila no existe.
     * @throws IllegalArgumentException si la fila no es kind=QUERY.
     * @throws ProvisioningException si el provisioner rechaza el
     *         borrado o la creación, o si la instancia nueva no
     *         aparece en Eureka a tiempo.
     */
    public void recreateContainer(Long id) {
        Microservice m = repo.findById(id)
                .orElseThrow(() -> new NotFoundException("Microservice", id));
        if (!"QUERY".equals(m.getKind())) {
            throw new IllegalArgumentException(
                    "El microservicio " + id + " es kind=" + m.getKind()
                            + "; sólo las filas kind=QUERY tienen contenedor que recrear");
        }
        String instanceId = m.getInstanceName() != null ? m.getInstanceName() : m.getDialect();
        String fullName = "query-service-" + instanceId;

        // deprovision es idempotente sobre un contenedor ausente
        // (ver ContainerProvisioner#deprovision) — no hace falta
        // comprobar el estado antes de borrar.
        provisioner.deprovision(fullName);
        log.info("recreateContainer: {} borrado, re-provisionando con la imagen actual", fullName);

        provisioner.provision(new ProvisionSpec(
                instanceId,
                m.getDialect(),
                m.getJdbcUrl(),
                m.getDbUsername(),
                m.getDbPassword(),
                m.getPoolSize() != null ? m.getPoolSize() : 10));
        readinessProbe.waitForInstance(fullName);
        log.info("recreateContainer: {} re-provisionado y registrado en Eureka", fullName);
    }

    @Transactional
    public MicroserviceResponse update(MicroserviceRequest req) {
        if (req.id() == null) {
            throw new IllegalArgumentException("El id es obligatorio para actualizar");
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
                    name + " es obligatorio cuando kind=QUERY");
        }
    }

    /**
     * Sonda sin persistencia usada por el botón "Probar conexión"
     * del drawer y por el gate de {@link #create(MicroserviceRequest)}.
     * Delega en {@link JdbcConnectionProbe}, que aísla la llamada
     * estática a {@code DriverManager}.
     */
    public MicroserviceTestConnectionResponse testConnection(MicroserviceTestConnectionRequest req) {
        return connectionProbe.probe(req);
    }
}
