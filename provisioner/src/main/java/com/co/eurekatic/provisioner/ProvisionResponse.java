package com.co.eurekatic.provisioner;

/**
 * Response body for {@code POST /provision} (201) and
 * {@code GET /provision/{name}/status} (200).
 *
 * <p>{@code startedAt} and {@code rawState} are only populated
 * by the status endpoint (the create response always returns
 * {@code status="running"} because container start is
 * synchronous in {@link DockerSocket#createAndStart}). When
 * the container is missing, {@link DockerSocket#status} returns
 * the synthetic state {@code "absent"} so callers can render
 * a badge without special-casing 404.
 *
 * <p>The create path uses the 3-arg compact constructor so
 * the create response carries explicit {@code null} for
 * {@code startedAt} and {@code rawState}. Older sso-admin
 * builds deserialize fine (Jackson ignores unknown fields on
 * read), and the wire shape stays consistent across the two
 * endpoints.
 */
public record ProvisionResponse(
        /** Full instance id, e.g. {@code query-service-oracle-dev}. */
        String instanceName,
        /** Container id returned by the Docker Engine API. */
        String containerId,
        /**
         * Lifecycle state from Docker ({@code created | running |
         * exited | paused | restarting | dead | removing}) or the
         * synthetic {@code "absent"} when the container does not
         * exist on the host. The status endpoint always returns
         * 200 — never 404 — so clients render the absence rather
         * than treat it as a transport failure.
         */
        String status,
        /** RFC 3339 timestamp of the last start, from Docker inspect. */
        String startedAt,
        /** Original Docker state string, before any normalization. */
        String rawState
) {
    /** Compact constructor used by the create path. */
    public ProvisionResponse(String instanceName, String containerId, String status) {
        this(instanceName, containerId, status, null, null);
    }
}