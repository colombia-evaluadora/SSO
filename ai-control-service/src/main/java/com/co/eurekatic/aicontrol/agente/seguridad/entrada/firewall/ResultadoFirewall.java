package com.co.eurekatic.aicontrol.agente.seguridad.entrada.firewall;

import com.co.eurekatic.aicontrol.agente.seguridad.Motivo;
import com.co.eurekatic.aicontrol.agente.seguridad.Riesgo;

import java.util.Optional;

/**
 * Veredicto del firewall determinista.
 *
 * @param permitido        si el texto puede seguir al modelo; false para ALTO y para una entrada vacia
 * @param textoNormalizado texto tras NFKC y quitar caracteres de control; es lo que se audita por huella
 * @param riesgo           BAJO, MEDIO o ALTO
 * @param motivo           codigo del hallazgo; vacio si no hay hallazgo y en BAJO solo para la entrada vacia
 */
public record ResultadoFirewall(boolean permitido, String textoNormalizado, Riesgo riesgo,
                                Optional<Motivo> motivo) {
}
