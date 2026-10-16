package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import com.co.eurekatic.aicontrol.agente.comun.ErrorAgente;
import org.springframework.stereotype.Component;

import java.util.Objects;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Un turno a la vez por usuario y por instancia. Evita que una persona ocupe todas las plazas del
 * razonador con mensajes en paralelo y que dos turnos de la misma conversacion se pisen la memoria.
 *
 * <p>Un turno se puede cancelar: se marca su {@link SenalCancelacion} y la reserva se libera en el acto,
 * sin esperar a que el hilo termine, para que la persona pueda escribir otra vez enseguida.
 */
@Component
public class TurnosEnCurso {

    private final ConcurrentHashMap<Long, Turno> activos = new ConcurrentHashMap<>();

    /** Reserva sin conversacion asociada (no se puede cancelar por conversacion). */
    public Turno abrir(long userId) {
        return abrir(userId, null);
    }

    /**
     * Reserva el turno del usuario; se libera al cerrar el {@link Turno} o al cancelarlo.
     *
     * @throws ErrorAgente.TurnoEnCurso si el usuario ya tiene uno en marcha
     */
    public Turno abrir(long userId, UUID conversacionId) {
        Turno turno = new Turno(userId, conversacionId);
        if (activos.putIfAbsent(userId, turno) != null) {
            throw new ErrorAgente.TurnoEnCurso();
        }
        return turno;
    }

    /**
     * Cancela el turno en curso del usuario en esa conversacion.
     *
     * @return false si no habia ninguno en marcha para esa conversacion
     */
    public boolean cancelar(long userId, UUID conversacionId) {
        Turno turno = activos.get(userId);
        if (turno == null || !Objects.equals(turno.conversacionId, conversacionId)) {
            return false;
        }
        turno.senal.cancelar();
        return activos.remove(userId, turno);
    }

    /** Reserva de un turno; se usa con try-with-resources. Cerrarla solo libera la suya, no una posterior. */
    public final class Turno implements AutoCloseable {

        private final long userId;
        private final UUID conversacionId;
        private final SenalCancelacion senal = new SenalCancelacion();

        private Turno(long userId, UUID conversacionId) {
            this.userId = userId;
            this.conversacionId = conversacionId;
        }

        public SenalCancelacion senal() {
            return senal;
        }

        @Override
        public void close() {
            activos.remove(userId, this);
        }
    }
}
