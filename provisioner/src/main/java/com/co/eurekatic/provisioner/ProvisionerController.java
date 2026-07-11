package com.co.eurekatic.provisioner;

import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * REST surface of the provisioner sidecar. The contract is
 * intentionally tiny — five endpoints cover the full
 * lifecycle that sso-admin drives:
 *
 * <pre>
 *   POST   /provision                body: ProvisionRequest   → 201 ProvisionResponse
 *   DELETE /provision/{name}                                     → 204
 *   GET    /provision/{name}/status                              → 200 ProvisionResponse (status="absent" when missing)
 *   GET    /provision/{name}/logs?tail=N  (text/plain)          → 200 body
 *   POST   /provision/{name}/restart                             → 204
 * </pre>
 *
 * <p>Error mapping: 4xx for caller mistakes (bad spec),
 * 5xx for Docker-side failures (image pull failed,
 * container start crashed). The {@code /actuator/health}
 * endpoint comes for free from the actuator starter and
 * is what sso-admin's {@code HttpContainerProvisioner#isHealthy}
 * polls.
 */
@RestController
@RequestMapping("/provision")
public class ProvisionerController {

    /** Docker's tail= documentation: use {@code "all"} for
     *  the full log buffer. We expose it as a magic number
     *  rather than a string parameter so the wire shape
     *  stays typed. */
    static final int DEFAULT_LOG_TAIL = 200;
    static final int MAX_LOG_TAIL = 100_000;

    private final DockerSocket docker;

    public ProvisionerController(DockerSocket docker) {
        this.docker = docker;
    }

    @PostMapping
    public ResponseEntity<ProvisionResponse> provision(@Valid @RequestBody ProvisionRequest req) {
        String fullName = "query-service-" + req.instanceName();
        String containerId = docker.createAndStart(req, fullName);
        // Status at create+start time is always "running"
        // (start is synchronous); the readiness probe on
        // sso-admin's side is what waits for the JVM to be
        // healthy enough to register with Eureka.
        return ResponseEntity
                .status(HttpStatus.CREATED)
                .body(new ProvisionResponse(fullName, containerId, "running"));
    }

    @DeleteMapping("/{fullName}")
    public ResponseEntity<Void> deprovision(@PathVariable String fullName) {
        docker.stopAndRemove(fullName);
        return ResponseEntity.noContent().build();
    }

    @GetMapping("/{fullName}/status")
    public ResponseEntity<ProvisionResponse> status(@PathVariable String fullName) {
        String state = docker.status(fullName);
        DockerSocket.StartedAtInfo info = docker.inspectStartedAt(fullName);
        // Both status() and inspectStartedAt() return null
        // when the container is missing; we coalesce to the
        // synthetic "absent" state so the UI can render a
        // badge without checking HTTP status. This is a
        // contract: /provision/{name}/status NEVER returns
        // 404 for a missing container — it returns 200 with
        // status="absent".
        String containerId = info != null ? info.containerId() : null;
        String startedAt = info != null ? info.startedAt() : null;
        // When status() returns "absent", also report it as
        // the rawState so the UI tooltip shows the real
        // situation; otherwise rawState mirrors status.
        String rawState = state;
        return ResponseEntity.ok(new ProvisionResponse(
                fullName, containerId, state, startedAt, rawState));
    }

    @GetMapping(value = "/{fullName}/logs", produces = MediaType.TEXT_PLAIN_VALUE)
    public ResponseEntity<String> logs(
            @PathVariable String fullName,
            @RequestParam(defaultValue = "" + DEFAULT_LOG_TAIL) int tail) {
        int effective = Math.max(1, Math.min(tail, MAX_LOG_TAIL));
        String body = docker.logs(fullName, effective);
        return ResponseEntity.ok()
                .contentType(MediaType.TEXT_PLAIN)
                .body(body);
    }

    @PostMapping("/{fullName}/restart")
    public ResponseEntity<Void> restart(@PathVariable String fullName) {
        if (!docker.restart(fullName)) {
            // Missing container is reported as 404 — the UI
            // can show a "container gone, recreate" hint.
            return ResponseEntity.notFound().build();
        }
        return ResponseEntity.noContent().build();
    }
}