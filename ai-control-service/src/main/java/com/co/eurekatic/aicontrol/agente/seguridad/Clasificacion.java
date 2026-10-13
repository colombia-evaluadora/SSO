package com.co.eurekatic.aicontrol.agente.seguridad;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;

/**
 * Respuesta del clasificador de inyeccion. Lo que llega del modelo se parsea a
 * este tipo; {@link ClasificadorInyeccion} lo devuelve con el motivo ya
 * convertido en codigo, porque el texto libre del modelo no sale de la clase.
 *
 * @param riesgo BAJO, MEDIO o ALTO
 * @param motivo codigo corto del hallazgo, o null si el riesgo es BAJO
 */
@JsonIgnoreProperties(ignoreUnknown = true)
public record Clasificacion(Riesgo riesgo, String motivo) {

    /** El modelo marco el mensaje como sospechoso. */
    public static final String MOTIVO_SOSPECHA = "CLASIFICADOR_SOSPECHA";
    /** El clasificador no respondio o no se pudo leer su salida: se asume MEDIO. */
    public static final String MOTIVO_NO_DISPONIBLE = "CLASIFICADOR_NO_DISPONIBLE";
}
