package com.co.eurekatic.aicontrol.client;

import java.util.List;
import java.util.Map;
import java.util.Objects;

/**
 * Resultado de invocar una ruta de query-service. Cerrado: quien lo consume cubre
 * los tres casos.
 */
public sealed interface RespuestaQuery {

    /** Respuesta 2xx: las filas de la ruta. */
    record Exito(List<Map<String, Object>> filas) implements RespuestaQuery {
        public Exito {
            filas = List.copyOf(Objects.requireNonNull(filas, "filas"));
        }
    }

    /**
     * Respuesta 4xx: el query-service dice por que (403 del gate, 400 de validacion, 404...).
     * {@code mensaje} viene del query-service y es apto para el usuario.
     */
    record ErrorCliente(int status, String mensaje) implements RespuestaQuery {
    }

    /** 5xx, timeout o fallo de transporte. El detalle no sale de aqui. */
    record ErrorServidor() implements RespuestaQuery {
    }
}
