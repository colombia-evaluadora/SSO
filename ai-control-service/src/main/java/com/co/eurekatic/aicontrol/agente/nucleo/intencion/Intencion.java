package com.co.eurekatic.aicontrol.agente.nucleo.intencion;

import com.co.eurekatic.aicontrol.agente.seguridad.Riesgo;

import java.util.Objects;

/**
 * Intencion del mensaje, decidida por el modelo rapido.
 *
 * @param tipo      clase de peticion
 * @param accion    codigo corto de la accion que sugiere el modelo (p. ej. {@code CREAR_FUNCIONARIO});
 *                  cadena vacia si no sugiere ninguna. Es una pista para el registro: la autoridad
 *                  sobre lo que se puede hacer la dan las herramientas del turno
 * @param confianza de 0 a 1, tal como la declara el modelo
 * @param riesgo    riesgo final de la entrada, con el que se filtran las herramientas
 */
public record Intencion(TipoIntencion tipo, String accion, double confianza, Riesgo riesgo) {

    public Intencion {
        Objects.requireNonNull(tipo, "tipo");
        Objects.requireNonNull(accion, "accion");
        Objects.requireNonNull(riesgo, "riesgo");
        confianza = Double.isNaN(confianza) ? 0.0 : Math.min(1.0, Math.max(0.0, confianza));
    }
}
