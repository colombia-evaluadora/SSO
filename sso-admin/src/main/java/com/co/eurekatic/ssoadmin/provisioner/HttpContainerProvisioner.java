package com.co.eurekatic.ssoadmin.provisioner;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatusCode;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;

/**
 * Production {@link ContainerProvisioner} — translates the
 * spec into a {@code POST /provision} call to the
 * provisioner sidecar. The sidecar does the Docker Engine
 * API heavy lifting; sso-admin never opens the unix socket
 * directly.
 *
 * <p>Wire contract (matches the sidecar's REST surface —
 * see {@code provisioner/.../DockerContainerProvisioner}):
 * <pre>
 *   POST /provision         body: ProvisionSpec         → 201 { containerId }
 *   DELETE /provision/{name}                         → 204
 *   GET  /provision/{name}/status                   → 200 { status }
 *   GET  /actuator/health                          → 200 UP
 * </pre>
 *
 * <p>Error mapping:
 * <ul>
 *   <li>{@code 4xx} sidecar response (other than 404 on
 *       delete) → {@link ProvisioningException.Code#CONTAINER_CREATE_FAILED}
 *       with the sidecar's body in the message.</li>
 *   <li>{@code 5xx} or connection refused →
 *       {@link ProvisioningException.Code#SIDECAR_UNREACHABLE}.</li>
 *   <li>{@code DELETE} returning 404 is treated as success
 *       (idempotent).</li>
 * </ul>
 */
@Component
public class HttpContainerProvisioner implements ContainerProvisioner {

    private static final Logger log = LoggerFactory.getLogger(HttpContainerProvisioner.class);

    private final RestClient client;

    @org.springframework.beans.factory.annotation.Autowired
    public HttpContainerProvisioner(ProvisionerClientConfig cfg) {
        this(RestClient.builder()
                .baseUrl(cfg.getBaseUrl())
                .defaultHeader("Accept", MediaType.APPLICATION_JSON_VALUE));
    }

    /**
     * Package-private constructor for tests — accepts a
     * {@link RestClient.Builder} that may have been bound
     * to a {@code MockRestServiceServer}. Production code
     * uses the {@link ProvisionerClientConfig} constructor
     * above.
     */
    HttpContainerProvisioner(RestClient.Builder builder) {
        this.client = builder
                .defaultHeader("Accept", MediaType.APPLICATION_JSON_VALUE)
                .build();
    }

    @Override
    public void provision(ProvisionSpec spec) {
        try {
            client.post()
                    .uri("/provision")
                    .contentType(MediaType.APPLICATION_JSON)
                    .body(spec)
                    .retrieve()
                    .onStatus(HttpStatusCode::is4xxClientError, (req, res) -> {
                        throw new ProvisioningException(
                                ProvisioningException.Code.CONTAINER_CREATE_FAILED,
                                "Provisioner refused create for "
                                        + spec.instanceName() + ": " + res.getStatusText());
                    })
                    .onStatus(HttpStatusCode::is5xxServerError, (req, res) -> {
                        throw new ProvisioningException(
                                ProvisioningException.Code.CONTAINER_CREATE_FAILED,
                                "Provisioner 5xx on create for "
                                        + spec.instanceName() + ": " + res.getStatusText());
                    })
                    .toBodilessEntity();
            log.info("Provisioner accepted create for {}", spec.instanceName());
        } catch (ProvisioningException pe) {
            throw pe;
        } catch (RestClientException e) {
            log.warn("Provisioner unreachable on create for {}: {}",
                    spec.instanceName(), e.getMessage());
            throw new ProvisioningException(
                    ProvisioningException.Code.SIDECAR_UNREACHABLE,
                    "Provisioner unreachable: " + e.getMessage(), e);
        }
    }

    @Override
    public void deprovision(String fullInstanceName) {
        try {
            client.delete()
                    .uri("/provision/{name}", fullInstanceName)
                    .retrieve()
                    .onStatus(HttpStatusCode::is4xxClientError, (req, res) -> {
                        // 404 is the "already gone" success path
                        // for an idempotent delete — anything
                        // else is a real error.
                        if (res.getStatusCode().value() == 404) {
                            log.info("Provisioner reports {} already gone", fullInstanceName);
                            return;
                        }
                        throw new ProvisioningException(
                                ProvisioningException.Code.CONTAINER_CREATE_FAILED,
                                "Provisioner refused delete for "
                                        + fullInstanceName + ": " + res.getStatusText());
                    })
                    .onStatus(HttpStatusCode::is5xxServerError, (req, res) -> {
                        throw new ProvisioningException(
                                ProvisioningException.Code.CONTAINER_CREATE_FAILED,
                                "Provisioner 5xx on delete for "
                                        + fullInstanceName + ": " + res.getStatusText());
                    })
                    .toBodilessEntity();
        } catch (ProvisioningException pe) {
            throw pe;
        } catch (RestClientException e) {
            log.warn("Provisioner unreachable on delete for {}: {}",
                    fullInstanceName, e.getMessage());
            throw new ProvisioningException(
                    ProvisioningException.Code.SIDECAR_UNREACHABLE,
                    "Provisioner unreachable: " + e.getMessage(), e);
        }
    }

    @Override
    public boolean isHealthy() {
        try {
            client.get()
                    .uri("/actuator/health")
                    .retrieve()
                    .onStatus(s -> true, (req, res) -> { /* swallow */ })
                    .toBodilessEntity();
            return true;
        } catch (RestClientException e) {
            return false;
        }
    }

    /**
     * Wire contract: {@code GET /provision/{fullName}/status}
     * always returns 200 — the {@code status} field carries
     * the synthetic {@code "absent"} when the container is
     * gone. We deserialize straight into our internal
     * {@link ContainerStatus} record; field names line up
     * 1:1 with the provisioner's {@code ProvisionResponse}.
     */
    @Override
    public ContainerStatus status(String fullInstanceName) {
        try {
            ProvisionResponseDto body = client.get()
                    .uri("/provision/{name}/status", fullInstanceName)
                    .retrieve()
                    .onStatus(HttpStatusCode::is4xxClientError, (req, res) -> {
                        throw new ProvisioningException(
                                ProvisioningException.Code.CONTAINER_CREATE_FAILED,
                                "Provisioner refused status for "
                                        + fullInstanceName + ": " + res.getStatusText());
                    })
                    .onStatus(HttpStatusCode::is5xxServerError, (req, res) -> {
                        throw new ProvisioningException(
                                ProvisioningException.Code.SIDECAR_UNREACHABLE,
                                "Provisioner 5xx on status for "
                                        + fullInstanceName + ": " + res.getStatusText());
                    })
                    .body(ProvisionResponseDto.class);
            if (body == null || body.status() == null) {
                // Defensive: the sidecar contract is 200+status,
                // but if it ever sends an empty body we treat
                // it as "unknown" so the UI badge has something
                // to render.
                return new ContainerStatus("unknown", null, null, null, fullInstanceName);
            }
            return new ContainerStatus(
                    body.status(),
                    body.rawState() != null ? body.rawState() : body.status(),
                    body.containerId(),
                    body.startedAt(),
                    body.instanceName() != null ? body.instanceName() : fullInstanceName);
        } catch (ProvisioningException pe) {
            throw pe;
        } catch (RestClientException e) {
            log.warn("Provisioner unreachable on status for {}: {}",
                    fullInstanceName, e.getMessage());
            throw new ProvisioningException(
                    ProvisioningException.Code.SIDECAR_UNREACHABLE,
                    "Provisioner unreachable: " + e.getMessage(), e);
        }
    }

    /**
     * Wire contract: {@code GET /provision/{fullName}/logs?tail=N}
     * returns 200 with a {@code text/plain} body. The response
     * is a {@code String} — we use {@code body(String.class)}
     * so Jackson reads the body as a raw string rather than
     * trying to JSON-decode it. Empty bodies are coalesced
     * to {@code ""} — RestClient would otherwise return null
     * for an empty 200, and the admin-ui would have to
     * special-case that on every render.
     */
    @Override
    public String logs(String fullInstanceName, int tail) {
        try {
            String body = client.get()
                    .uri(uri -> uri
                            .path("/provision/{name}/logs")
                            .queryParam("tail", Math.max(1, tail))
                            .build(fullInstanceName))
                    .retrieve()
                    .onStatus(HttpStatusCode::is4xxClientError, (req, res) -> {
                        throw new ProvisioningException(
                                ProvisioningException.Code.CONTAINER_CREATE_FAILED,
                                "Provisioner refused logs for "
                                        + fullInstanceName + ": " + res.getStatusText());
                    })
                    .onStatus(HttpStatusCode::is5xxServerError, (req, res) -> {
                        throw new ProvisioningException(
                                ProvisioningException.Code.SIDECAR_UNREACHABLE,
                                "Provisioner 5xx on logs for "
                                        + fullInstanceName + ": " + res.getStatusText());
                    })
                    .body(String.class);
            return body != null ? body : "";
        } catch (ProvisioningException pe) {
            throw pe;
        } catch (RestClientException e) {
            log.warn("Provisioner unreachable on logs for {}: {}",
                    fullInstanceName, e.getMessage());
            throw new ProvisioningException(
                    ProvisioningException.Code.SIDECAR_UNREACHABLE,
                    "Provisioner unreachable: " + e.getMessage(), e);
        }
    }

    /**
     * Wire contract: {@code POST /provision/{fullName}/restart}
     * returns 204 on success, 404 when the container is gone.
     * The 404 is the expected response for an absent container —
     * we report it as {@code false} to the caller, NOT as an
     * exception, so the controller can decide whether to 404
     * the admin-ui or just render an "absent" badge.
     */
    @Override
    public boolean restart(String fullInstanceName) {
        try {
            client.post()
                    .uri("/provision/{name}/restart", fullInstanceName)
                    .retrieve()
                    .onStatus(HttpStatusCode::is4xxClientError, (req, res) -> {
                        if (res.getStatusCode().value() == 404) {
                            // "gone" — handle below by returning false.
                            throw new ContainerGoneException(fullInstanceName);
                        }
                        throw new ProvisioningException(
                                ProvisioningException.Code.CONTAINER_CREATE_FAILED,
                                "Provisioner refused restart for "
                                        + fullInstanceName + ": " + res.getStatusText());
                    })
                    .onStatus(HttpStatusCode::is5xxServerError, (req, res) -> {
                        throw new ProvisioningException(
                                ProvisioningException.Code.CONTAINER_CREATE_FAILED,
                                "Provisioner 5xx on restart for "
                                        + fullInstanceName + ": " + res.getStatusText());
                    })
                    .toBodilessEntity();
            return true;
        } catch (ContainerGoneException gone) {
            log.info("Restart requested on missing container {}", fullInstanceName);
            return false;
        } catch (ProvisioningException pe) {
            throw pe;
        } catch (RestClientException e) {
            log.warn("Provisioner unreachable on restart for {}: {}",
                    fullInstanceName, e.getMessage());
            throw new ProvisioningException(
                    ProvisioningException.Code.SIDECAR_UNREACHABLE,
                    "Provisioner unreachable: " + e.getMessage(), e);
        }
    }

    /**
     * Internal sentinel — thrown by the {@code onStatus} handler
     * when the provisioner returns 404 from {@code /restart}.
     * Caught one frame up in {@link #restart(String)} and
     * translated to a {@code false} return so callers can
     * distinguish "restarted" from "container was already gone".
     */
    private static final class ContainerGoneException extends RuntimeException {
        ContainerGoneException(String name) { super(name); }
    }

    /**
     * Mirror of the provisioner's {@code ProvisionResponse}.
     * Kept private to this class so we don't bleed the wire
     * shape into the rest of sso-admin — callers always go
     * through {@link ContainerStatus}.
     */
    private record ProvisionResponseDto(
            String instanceName,
            String containerId,
            String status,
            String startedAt,
            String rawState
    ) {}
}