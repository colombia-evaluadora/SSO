package com.co.eurekatic.aicontrol.agente.web.dto;

import jakarta.validation.constraints.NotBlank;
import tools.jackson.databind.JsonNode;

/**
 * Mensaje nuevo del usuario.
 *
 * @param texto      lo que escribe la persona; no puede estar vacio
 * @param contextoUi estado de la pantalla en que esta, opcional; se trata como dato
 */
public record MensajeRequest(@NotBlank String texto, JsonNode contextoUi) {
}
