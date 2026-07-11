package com.co.eurekatic.ssoadmin.provisioner;

/**
 * Boundary the {@link com.co.eurekatic.ssoadmin.service.MicroserviceService}
 * uses to talk to the provisioner sidecar. The production
 * implementation is {@code HttpContainerProvisioner}, which uses
 * Spring's {@code RestClient} under the hood.
 *
 * <p>This interface exists for two reasons:
 * <ol>
 *   <li>The {@code MicroserviceService} unit tests can swap in
 *       a Mockito mock instead of booting an HTTP client.</li>
 *   <li>If we ever swap Docker Engine API for a Kubernetes
 *       operator, only this interface changes — the service
 *       stays put.</li>
 * </ol>
 */
public interface ContainerProvisioner {

    /**
     * Ask the provisioner to start a fresh {@code query-service}
     * container matching the spec. Blocks until the
     * {@code POST /v1.43/containers/create} + {@code /start}
     * round-trip completes.
     *
     * @throws ProvisioningException when the sidecar is
     *         unreachable, the Docker daemon rejects the
     *         create, or the container fails to stay up.
     */
    void provision(ProvisionSpec spec);

    /**
     * Best-effort delete of the container with the given
     * full instance id ({@code query-service-<suffix>}). Never
     * throws on a missing container — that is the success
     * path for an idempotent delete.
     *
     * @throws ProvisioningException only when the sidecar is
     *         unreachable.
     */
    void deprovision(String fullInstanceName);

    /**
     * Cheap check that the sidecar is alive (used by the
     * {@code /actuator/health} downstream chain, not by
     * {@code MicroserviceService}).
     */
    boolean isHealthy();

    /**
     * Container runtime status. The provisioner returns
     * {@code state="absent"} when the container is gone (the
     * HTTP call still returns 200 — this is a deliberate
     * contract with the admin-ui badge component, which
     * renders "ABSENT" rather than throwing on a missing
     * container).
     *
     * @return never null — the {@code state} field carries
     *         the absent/provisioning/unknown signal.
     * @throws ProvisioningException only when the sidecar is
     *         unreachable.
     */
    ContainerStatus status(String fullInstanceName);

    /**
     * Last N lines of {@code stdout}+{@code stderr} for the
     * container, demuxed into a single UTF-8 string. The
     * provisioner clamps {@code tail} to a sane upper bound
     * (100k) so a misbehaving operator cannot pull gigabytes
     * over the wire.
     *
     * @throws ProvisioningException when the sidecar or the
     *         Docker daemon reports a hard failure (a missing
     *         container is reported as an empty string — that
     *         is a normal state, not an error).
     */
    String logs(String fullInstanceName, int tail);

    /**
     * {@code POST /containers/{name}/restart?t=10}. Returns
     * true when the container existed and was restarted;
     * false when the container is gone (the admin-ui badge
     * for "absent" is the operator's signal to recreate).
     *
     * @throws ProvisioningException when the sidecar is
     *         unreachable or the Docker daemon returns a
     *         non-404 error.
     */
    boolean restart(String fullInstanceName);

    /**
     * Container runtime status snapshot. Backed by the
     * provisioner's {@code GET /provision/{name}/status}
     * (which in turn calls {@code GET /containers/{name}/json}
     * on the Docker Engine API).
     *
     * @param state       Docker state ({@code running | exited
     *                    | created | paused | restarting | dead
     *                    | removing}) or the synthetic
     *                    {@code "absent"} when the container
     *                    does not exist.
     * @param rawState    Mirror of {@code state}, kept as a
     *                    separate field for forward
     *                    compatibility — when we add state
     *                    normalization, {@code state} becomes
     *                    the normalized value and {@code rawState}
     *                    preserves the original.
     * @param containerId Docker container id (full SHA) or
     *                    null when absent.
     * @param startedAt   RFC 3339 timestamp of the last
     *                    container start or null when absent.
     * @param fullName    Full container name passed to the
     *                    provisioner (echoes back the input).
     */
    record ContainerStatus(
            String state,
            String rawState,
            String containerId,
            String startedAt,
            String fullName
    ) {}
}