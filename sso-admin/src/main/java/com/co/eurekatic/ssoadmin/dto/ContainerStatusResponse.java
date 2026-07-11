package com.co.eurekatic.ssoadmin.dto;

/**
 * Container status payload returned by
 * {@code GET /sso-admin/microservice/{id}/container/status}.
 *
 * <p>The shape mirrors the admin-ui {@code ContainerStatusResponse}
 * (see {@code admin-ui/src/api/types.ts}). The {@code state}
 * enum covers every value the Docker Engine API can return
 * ({@code running | exited | created | paused | restarting |
 * dead | removing}) plus three synthetic states surfaced by
 * the backend:
 *
 * <ul>
 *   <li>{@code provisioning} — row exists, container does not
 *       yet (or no longer does); rendered as a yellow badge
 *       while the operator waits.</li>
 *   <li>{@code absent} — Docker returned 404 (container gone
 *       after a manual {@code docker rm} or a deprovision race);
 *       rendered red.</li>
 *   <li>{@code unknown} — provisioner unreachable; rendered
 *       slate so the operator sees we lost contact.</li>
 * </ul>
 *
 * @param state       Normalized state — drives the badge color.
 * @param rawState    Original Docker state string, surfaced in
 *                    the badge tooltip for debugging.
 * @param containerId Docker container id (full SHA), null when
 *                    absent.
 * @param startedAt   RFC 3339 timestamp of the last start. Null
 *                    when absent or before the first start.
 * @param fullName    Full container name ({@code query-service-<suffix>}).
 */
public record ContainerStatusResponse(
        String state,
        String rawState,
        String containerId,
        String startedAt,
        String fullName
) {}