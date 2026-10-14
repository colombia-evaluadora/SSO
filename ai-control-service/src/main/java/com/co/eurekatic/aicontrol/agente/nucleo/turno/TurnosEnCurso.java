package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import com.co.eurekatic.aicontrol.agente.comun.ErrorAgente;
import org.springframework.stereotype.Component;

import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Un turno a la vez por usuario y por instancia. Evita que una persona ocupe todas las plazas del
 * razonador con mensajes en paralelo y que dos turnos de la misma conversacion se pisen la memoria.
 */
@Component
public class TurnosEnCurso {

    private final Set<Long> activos = ConcurrentHashMap.newKeySet();

    /**
     * Reserva el turno del usuario; se libera al cerrar el {@link Turno}.
     *
     * @throws ErrorAgente.TurnoEnCurso si el usuario ya tiene uno en marcha
     */
    public Turno abrir(long userId) {
        if (!activos.add(userId)) {
            throw new ErrorAgente.TurnoEnCurso();
        }
        return () -> activos.remove(userId);
    }

    /** Reserva de un turno; se usa con try-with-resources. */
    @FunctionalInterface
    public interface Turno extends AutoCloseable {
        @Override
        void close();
    }
}
