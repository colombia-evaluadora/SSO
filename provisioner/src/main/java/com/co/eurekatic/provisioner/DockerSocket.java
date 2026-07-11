package com.co.eurekatic.provisioner;

import tools.jackson.databind.JsonNode;
import tools.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.TimeUnit;

/**
 * Talks to the Docker Engine API over the unix socket
 * mounted at {@code /var/run/docker.sock} by spawning
 * {@code curl --unix-socket}. Why curl and not the JDK's
 * {@link java.net.http.HttpClient}: the JDK's unix-socket
 * support requires either an incubating preview API or a
 * custom {@code SocketImpl} hack. {@code curl} is in every
 * base image we ship, doesn't add a dependency, and the
 * call shape (POST/DELETE/GET with a JSON body) maps 1:1 to
 * the Docker API surface.
 *
 * <p>Test seam: this class is the only {@code curl}-spawning
 * code in the app, so a unit test can swap in a fake
 * {@link DockerSocket} via the {@code DockerCommand} wrapper
 * if we ever need to. In practice the integration tests use
 * Testcontainers against a real Docker daemon, which is
 * what the existing modules do.
 */
@Component
public class DockerSocket {

    private static final Logger log = LoggerFactory.getLogger(DockerSocket.class);

    private final ProvisionerProperties props;
    private final ObjectMapper mapper = new ObjectMapper();

    public DockerSocket(ProvisionerProperties props) {
        this.props = props;
    }

    /**
     * {@code POST /v1.43/containers/create} + {@code POST
     * /v1.43/containers/{id}/start}. Returns the Docker
     * container id.
     *
     * @throws DockerException on any non-zero curl exit or
     *         Docker-reported error.
     */
    public String createAndStart(ProvisionRequest req, String fullInstanceName) {
        // POST /containers/create — body is a JSON spec
        // listing image, env, network on create (we attach
        // the container to the same compose network that
        // sso-admin lives on so service-name DNS works).
        //
        // ExposedPorts documents that the container listens
        // on 8084 inside the network; we DO NOT bind that to
        // a host port. Bind-to-host only makes sense for the
        // SINGLE canonical query-service-postgres in dev.
        // Every kind=QUERY instance is reached through the
        // gateway by its Docker DNS name
        // (`query-service-<instanceName>`), which Eureka
        // service-id equals, so no host port mapping is
        // needed. Mapping here would also collide: every
        // container asks for the same HostPort=8084 and
        // only the first one to come up wins, leaving the
        // rest stuck in "Created" with no recourse.
        String createBody = mapper.writeValueAsString(Map.of(
                "Image", props.getImage(),
                "Env", buildEnv(req),
                "ExposedPorts", Map.of("8084/tcp", Map.of()),
                "HostConfig", Map.of(
                        "NetworkMode", props.getNetwork(),
                        "RestartPolicy", Map.of("Name", "unless-stopped"))));

        JsonNode createResp = exec(List.of(
                "curl", "-sS", "-X", "POST",
                "--unix-socket", props.getSocketPath(),
                "-H", "Content-Type: application/json",
                "-d", createBody,
                "http://localhost/v1.43/containers/create?name=" + fullInstanceName));

        String containerId = createResp.path("Id").asText(null);
        if (containerId == null || containerId.isBlank()) {
            throw new DockerException("containers/create returned no Id: " + createResp);
        }

        exec(List.of(
                "curl", "-sS", "-X", "POST",
                "--unix-socket", props.getSocketPath(),
                "http://localhost/v1.43/containers/" + containerId + "/start"));

        log.info("Started container {} for {}", containerId, fullInstanceName);
        return containerId;
    }

    /**
     * {@code POST /v1.43/containers/{name}/stop} + {@code DELETE
     * /v1.43/containers/{name}?force=true}. Treats 404 as
     * success (idempotent delete).
     */
    public void stopAndRemove(String fullInstanceName) {
        // stop — best effort, ignore failures (already stopped)
        try {
            exec(List.of(
                    "curl", "-sS", "-X", "POST",
                    "--unix-socket", props.getSocketPath(),
                    "http://localhost/v1.43/containers/" + fullInstanceName + "/stop"));
        } catch (DockerException e) {
            log.debug("stop ignored for {}: {}", fullInstanceName, e.getMessage());
        }
        // remove with force=true — kills running container
        // if stop didn't take.
        try {
            exec(List.of(
                    "curl", "-sS", "-X", "DELETE",
                    "--unix-socket", props.getSocketPath(),
                    "http://localhost/v1.43/containers/" + fullInstanceName + "?force=true"));
        } catch (DockerException e) {
            if (e.getMessage().contains("404")) {
                log.info("Container {} already gone", fullInstanceName);
                return;
            }
            throw e;
        }
    }

    /**
     * {@code GET /v1.43/containers/{name}/json}. Returns the
     * Docker state string ({@code running}, {@code exited}, etc.)
     * or the synthetic {@code "absent"} when the container
     * doesn't exist. Callers (admin-ui) want 200-with-absent,
     * not 404 — a missing container is a normal operational
     * state ("just been deleted", "provisioning race"), not a
     * transport failure.
     */
    public String status(String fullInstanceName) {
        try {
            JsonNode resp = exec(List.of(
                    "curl", "-sS",
                    "--unix-socket", props.getSocketPath(),
                    "http://localhost/v1.43/containers/" + fullInstanceName + "/json"));
            JsonNode state = resp.path("State");
            // Inspect.State.Status is the human-readable state
            // ("running", "exited", ...). It can be absent when
            // the image has no entrypoint — fall back to "" so
            // callers can render an UNKNOWN badge instead of
            // crashing.
            return state.path("Status").asText("");
        } catch (DockerException e) {
            if (e.getMessage().contains("404")) {
                return "absent";
            }
            throw e;
        }
    }

    /**
     * Companion to {@link #status(String)} — pulls the
     * {@code State.StartedAt} timestamp and the raw container
     * id from the same Docker inspect response. Returns null
     * when the container is absent. We use the same curl call
     * as {@code status} to avoid a second round-trip.
     */
    public StartedAtInfo inspectStartedAt(String fullInstanceName) {
        try {
            JsonNode resp = exec(List.of(
                    "curl", "-sS",
                    "--unix-socket", props.getSocketPath(),
                    "http://localhost/v1.43/containers/" + fullInstanceName + "/json"));
            String containerId = resp.path("Id").asText(null);
            String startedAt = resp.path("State").path("StartedAt").asText(null);
            // Docker returns "0001-01-01T00:00:00Z" for a
            // container that has never been started (e.g. still
            // "created"). Normalize to null so the UI renders
            // "—" instead of the epoch.
            if (startedAt != null && startedAt.startsWith("0001-01-01")) {
                startedAt = null;
            }
            return new StartedAtInfo(containerId, startedAt);
        } catch (DockerException e) {
            if (e.getMessage().contains("404")) {
                return null;
            }
            throw e;
        }
    }

    /**
     * {@code GET /v1.43/containers/{name}/logs?stdout=true&stderr=true&tail=N}.
     *
     * <p>Docker's logs endpoint returns a STREAM multiplexed
     * binary payload — each frame has an 8-byte header
     * (1 byte type + 3 bytes padding + 4 bytes size BE). For
     * plain-text logs (the only thing query-service emits) we
     * skip the headers and concatenate the UTF-8 payload. This
     * is correct for ASCII / UTF-8 logs; binary payloads in
     * stdout (e.g. file uploads) would need a proper demuxer.
     * Spring Boot's default console output is text, so the
     * simplification holds for our use case.
     *
     * <p>Returns an empty string when the container has not
     * produced any output yet.
     */
    public String logs(String fullInstanceName, int tail) {
        // Cap tail at Docker's documented max (the API allows
        // "all" but operators should not request the full
        // log over the wire). 100k is arbitrary but generous.
        int effectiveTail = Math.max(1, Math.min(tail, 100_000));
        // curl --output - streams to stdout. We use
        // --no-buffer to keep the frames in order; otherwise
        // curl might reorder them as it writes.
        Process p;
        try {
            p = new ProcessBuilder(
                    "curl", "-sS", "--no-buffer",
                    "--unix-socket", props.getSocketPath(),
                    "http://localhost/v1.43/containers/" + fullInstanceName
                            + "/logs?stdout=true&stderr=true&tail="
                            + effectiveTail)
                    .redirectErrorStream(true)
                    .start();
        } catch (IOException e) {
            throw new DockerException("curl spawn failed for logs: " + e.getMessage(), e);
        }
        StringBuilder sb = new StringBuilder();
        try (java.io.InputStream in = p.getInputStream()) {
            byte[] header = new byte[8];
            byte[] chunk = new byte[8192];
            int n;
            while ((n = in.read(header)) != -1) {
                if (n < 8) {
                    // partial header at EOF — Docker sometimes
                    // sends a short frame for the last line
                    break;
                }
                // header[0] is the stream type (0=stdin,
                // 1=stdout, 2=stderr). We accept any.
                int size = ((header[4] & 0xff) << 24)
                        | ((header[5] & 0xff) << 16)
                        | ((header[6] & 0xff) << 8)
                        | (header[7] & 0xff);
                int remaining = size;
                while (remaining > 0) {
                    int toRead = Math.min(remaining, chunk.length);
                    int read = in.read(chunk, 0, toRead);
                    if (read < 0) break;
                    sb.append(new String(chunk, 0, read, StandardCharsets.UTF_8));
                    remaining -= read;
                }
            }
        } catch (IOException e) {
            throw new DockerException("read logs failed: " + e.getMessage(), e);
        }
        try {
            if (!p.waitFor(15, TimeUnit.SECONDS)) {
                p.destroyForcibly();
                throw new DockerException("curl timed out on logs: " + fullInstanceName);
            }
            int exit = p.exitValue();
            if (exit != 0) {
                // 404 → no logs yet. Return empty string; the
                // UI distinguishes this from "container absent"
                // via the separate status endpoint.
                // The output is already consumed at this point,
                // so we can't include it in the message body —
                // log it for debugging.
                log.debug("curl logs exited {} for {}", exit, fullInstanceName);
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new DockerException("logs interrupted", e);
        }
        return sb.toString();
    }

    /**
     * {@code POST /v1.43/containers/{name}/restart?t=10}.
     * The {@code t} parameter is the grace period (seconds)
     * before SIGKILL. Returns true on success, false when
     * the container is missing (the UI shows the missing
     * state and the operator can re-create from the page).
     */
    public boolean restart(String fullInstanceName) {
        try {
            exec(List.of(
                    "curl", "-sS", "-X", "POST",
                    "--unix-socket", props.getSocketPath(),
                    "http://localhost/v1.43/containers/" + fullInstanceName + "/restart?t=10"));
            return true;
        } catch (DockerException e) {
            if (e.getMessage().contains("404")) {
                return false;
            }
            throw e;
        }
    }

    /**
     * Container id + RFC 3339 {@code StartedAt} timestamp
     * returned by {@link #inspectStartedAt(String)}. Both
     * fields can be null (the inspect payload doesn't always
     * include them).
     */
    public record StartedAtInfo(String containerId, String startedAt) {}

    private List<String> buildEnv(ProvisionRequest req) {
        // The instance id (e.g. query-service-oracle-dev) is
        // what query-service registers with Eureka under. We
        // set spring.application.name via INSTANCE_NAME so
        // the InstanceNameResolver picks the right service-id
        // and the gateway's discovery.locator creates a
        // matching route.
        List<String> env = new ArrayList<>();
        env.add("QUERY_DS_DIALECT=" + req.dialect());
        // Instance-mode env vars (bound by query-service's
        // InstanceProps @ConfigurationProperties(prefix = "query.ds")).
        // When QUERY_DS_DIALECT is set, DataSourceConfig runs
        // in INSTANCE mode and reads these — the YAML's
        // QUERY_DS_POSTGRES_* are only read in STATIC mode
        // (no dialect env). See query-service's
        // InstanceProps.java javadoc for the full mapping.
        env.add("QUERY_DS_URL=" + req.jdbcUrl());
        env.add("QUERY_DS_USERNAME=" + req.dbUsername());
        if (req.dbPassword() != null) {
            env.add("QUERY_DS_PASSWORD=" + req.dbPassword());
        }
        env.add("QUERY_DS_POOL_SIZE=" + req.poolSize());
        env.add("QUERY_INSTANCE_NAME=" + req.instanceName());
        env.add("EUREKA_URL=" + props.getEurekaUrl());
        // JWT_SECRET must match auth-center's — the
        // query-service instance validates Bearer tokens
        // with the same HMAC key. Operator sets it in the
        // provisioner's compose env block.
        if (props.getJwtSecret() != null && !props.getJwtSecret().isBlank()) {
            env.add("JWT_SECRET=" + props.getJwtSecret());
        }
        // The catalog endpoint URL the new query-service
        // instance uses to resolve uuid→SQL. Defaults to
        // the gateway address, but operators can override
        // via environment if their network topology is
        // different.
        env.add("QUERY_CATALOG_BASE_URL=http://sso-api-gateway:8080/sso-admin");
        return env;
    }

    private JsonNode exec(List<String> command) {
        try {
            Process p = new ProcessBuilder(command)
                    .redirectErrorStream(true)
                    .start();
            String output;
            try (BufferedReader br = new BufferedReader(
                    new InputStreamReader(p.getInputStream(), StandardCharsets.UTF_8))) {
                StringBuilder sb = new StringBuilder();
                String line;
                while ((line = br.readLine()) != null) {
                    sb.append(line);
                }
                output = sb.toString();
            }
            if (!p.waitFor(30, TimeUnit.SECONDS)) {
                p.destroyForcibly();
                throw new DockerException("curl timed out: " + command);
            }
            int exit = p.exitValue();
            if (exit != 0) {
                throw new DockerException("curl exited " + exit + ": " + output);
            }
            if (output.isBlank()) {
                return mapper.createObjectNode();
            }
            return mapper.readTree(output);
        } catch (IOException | InterruptedException e) {
            if (e instanceof InterruptedException) {
                Thread.currentThread().interrupt();
            }
            throw new DockerException("curl spawn failed: " + e.getMessage(), e);
        }
    }

    /** Runtime exception wrapping any Docker Engine API failure. */
    public static class DockerException extends RuntimeException {
        public DockerException(String message) { super(message); }
        public DockerException(String message, Throwable cause) { super(message, cause); }
    }
}