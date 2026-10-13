package com.co.eurekatic.aicontrol.agente.seguridad;

/**
 * Veredicto combinado de la entrada: firewall y clasificador.
 *
 * @param permitido        false si el turno debe detenerse aqui
 * @param riesgo           maximo de los filtros que revisaron la entrada
 * @param motivo           codigo del filtro que dio el riesgo final; null si es BAJO
 * @param capa             filtro que dio el riesgo final; null si es BAJO
 * @param textoNormalizado texto tras el firewall, para auditar por huella
 */
public record Evaluacion(boolean permitido, Riesgo riesgo, String motivo, CapaSeguridad capa,
                         String textoNormalizado) {
}
