package com.co.eurekatic.aicontrol.agente.seguridad;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;

/**
 * Lo que el modelo devuelve al clasificar: solo el riesgo. El motivo en texto
 * libre del modelo se ignora y nunca sale de la clase de lectura.
 *
 * @param riesgo BAJO, MEDIO o ALTO
 */
@JsonIgnoreProperties(ignoreUnknown = true)
public record Clasificacion(Riesgo riesgo) {
}
