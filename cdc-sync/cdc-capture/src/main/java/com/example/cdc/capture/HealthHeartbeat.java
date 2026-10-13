package com.example.cdc.capture;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.health.actuate.endpoint.HealthEndpoint;
import org.springframework.boot.health.contributor.Status;
import org.springframework.scheduling.annotation.EnableScheduling;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.time.Instant;
import java.util.function.Supplier;

/**
 * Latido en fichero: cdc-capture no sirve HTTP, asi que el healthcheck de Docker mira el mtime
 * de este fichero. Se refresca mientras el estado agregado de Actuator es UP y se borra si no.
 */
@Component
@EnableScheduling
public class HealthHeartbeat {

    private static final Logger log = LoggerFactory.getLogger(HealthHeartbeat.class);

    private final Supplier<Status> estado;
    private final Path file;

    @Autowired
    public HealthHeartbeat(HealthEndpoint healthEndpoint,
                           @Value("${CDC_HEALTH_FILE:/tmp/cdc-health}") String file) {
        this(() -> healthEndpoint.health().getStatus(), file);
    }

    HealthHeartbeat(Supplier<Status> estado, String file) {
        this.estado = estado;
        this.file = Path.of(file);
    }

    @Scheduled(fixedDelayString = "${CDC_HEALTH_HEARTBEAT_MS:15000}")
    public void beat() {
        try {
            if (Status.UP.equals(estado.get())) {
                Files.writeString(file, Instant.now().toString(),
                        StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING);
            } else {
                Files.deleteIfExists(file);
            }
        } catch (Exception e) {
            log.warn("No se pudo actualizar el latido {}: {}", file, e.toString());
            try {
                Files.deleteIfExists(file);
            } catch (IOException ignored) {
                // sin fichero el healthcheck ya falla
            }
        }
    }
}
