package com.co.eurekatic.aicontrol.agente.seguridad;

import java.util.Optional;

/**
 * Segunda barrera de la entrada: decide si un mensaje ya normalizado intenta
 * manipular al asistente. La implementacion habitual consulta un modelo; el
 * contrato no depende de el.
 */
public interface ClasificadorRiesgo {

    /**
     * @return hallazgo MEDIO o ALTO, o vacio si el mensaje es BAJO. Nunca lanza:
     *         ante un fallo devuelve MEDIO, de modo que el turno sigue sin escrituras.
     */
    Optional<Hallazgo> clasificar(String textoNormalizado);
}
