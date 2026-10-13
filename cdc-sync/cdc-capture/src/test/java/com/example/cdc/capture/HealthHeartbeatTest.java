package com.example.cdc.capture;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.boot.health.contributor.Status;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class HealthHeartbeatTest {

    @TempDir
    Path dir;

    private HealthHeartbeat con(Status status, Path file) {
        return new HealthHeartbeat(() -> status, file.toString());
    }

    @Test
    void escribeElFicheroCuandoEstaUp() {
        Path f = dir.resolve("cdc-health");
        con(Status.UP, f).beat();
        assertTrue(Files.exists(f));
    }

    @Test
    void borraElFicheroCuandoEstaDown() throws Exception {
        Path f = dir.resolve("cdc-health");
        Files.writeString(f, "x");
        con(Status.DOWN, f).beat();
        assertFalse(Files.exists(f));
    }

    @Test
    void noFallaSiNoSePuedeEscribir() {
        Path f = dir.resolve("no-existe/cdc-health");
        con(Status.UP, f).beat();
        assertFalse(Files.exists(f));
    }
}
