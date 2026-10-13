package com.co.eurekatic.aicontrol.agente.seguridad;

/**
 * Veredicto del firewall determinista.
 *
 * @param permitido       si el texto puede seguir al modelo; false con riesgo BAJO solo para una entrada vacia
 * @param textoNormalizado texto tras NFKC y quitar caracteres de control; es lo que se audita por huella
 * @param riesgo          BAJO, MEDIO o ALTO
 * @param motivo          codigo corto de baja cardinalidad, o null si no hay hallazgo
 */
public record ResultadoFirewall(boolean permitido, String textoNormalizado, Riesgo riesgo, String motivo) {
}
