package com.co.eurekatic.aicontrol.agente.persistencia.mensaje;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Objects;
import java.util.UUID;

/**
 * Mensajes de una conversacion. El contenido llega ya anonimizado: el almacen no
 * sanea nada. Quien llama comprueba antes que la conversacion es del usuario.
 */
public interface MensajeStore {

    /** Fila de {@code ai.mensaje}. */
    record Mensaje(long id, UUID conversacionId, int secuencia, RolMensaje rol, String contenido,
                   String tipoRespuesta, String accionesUi, LocalDateTime createdAt) {

        public Mensaje {
            Objects.requireNonNull(rol, "rol");
        }
    }

    /**
     * Datos de un mensaje nuevo. {@code accionesUiJson} es JSON o null; los
     * tokens son null cuando el mensaje no vino del modelo.
     */
    record NuevoMensaje(RolMensaje rol, String contenido, String tipoRespuesta, String accionesUiJson,
                        String modelo, Integer tokensEntrada, Integer tokensSalida,
                        Integer tokensRazonamiento, Integer latenciaMs) {

        public NuevoMensaje {
            Objects.requireNonNull(rol, "rol");
        }
    }

    /**
     * Inserta un mensaje con la siguiente secuencia de la conversacion y actualiza
     * su ultimo mensaje, en una sola transaccion.
     *
     * @return id del mensaje insertado
     */
    long insertar(UUID conversacionId, NuevoMensaje mensaje);

    /** Todos los mensajes activos, en orden de secuencia. */
    List<Mensaje> listar(UUID conversacionId);

    /** Solo los turnos de texto (USER y ASSISTANT), en orden. Base de la memoria de respaldo. */
    List<Mensaje> listarFinales(UUID conversacionId);
}
