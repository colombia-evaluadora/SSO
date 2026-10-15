package com.co.eurekatic.scheduler.nucleo;

import java.time.Duration;
import java.time.Instant;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;
import org.springframework.stereotype.Component;

/**
 * Ultimo resultado de cada tarea en ESTA replica. Es diagnostico, no
 * historial: se pierde al reiniciar y otra replica puede haber ejecutado un
 * disparo que aqui figura como omitido. El historial vive en las metricas.
 */
@Component
public class EstadoTareas {

    public enum Resultado { OK, ERROR, OMITIDA }

    public record Ultima(Instant inicio, Duration duracion, Resultado resultado, int intentos, String error) {
    }

    private final Map<String, Ultima> ultimas = new ConcurrentHashMap<>();

    void registrar(String tareaId, Ultima ultima) {
        ultimas.put(tareaId, ultima);
    }

    public Optional<Ultima> ultima(String tareaId) {
        return Optional.ofNullable(ultimas.get(tareaId));
    }
}
