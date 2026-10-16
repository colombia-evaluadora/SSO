package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.ResultadoHerramienta.RequiereConfirmacion;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;

/**
 * Como termina el bucle del razonador: con una respuesta, o con una escritura que espera confirmacion.
 */
public sealed interface ResultadoBucle {

    Uso uso();

    String modelo();

    /** El turno termina con esta respuesta (texto, pregunta o respuesta directa de control). */
    record Final(RespuestaAgente respuesta, Uso uso, String modelo) implements ResultadoBucle {
    }

    /**
     * El modelo pidio una escritura valida. Nada se ha ejecutado: el llamador la guarda como pendiente.
     *
     * @param confirmacion argumentos canonicos y resumen de la escritura
     * @param herramienta  herramienta de escritura a la que corresponde
     */
    record Propuesta(RequiereConfirmacion confirmacion, HerramientaDef herramienta, Uso uso, String modelo)
            implements ResultadoBucle {
    }
}
