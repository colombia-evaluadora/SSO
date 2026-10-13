package com.co.eurekatic.aicontrol.agente.memoria;

import java.util.List;

/**
 * Forma JSON de un mensaje en la memoria de Redis. Es un DTO propio y no el de
 * Spring AI, cuyo formato no es estable entre versiones.
 *
 * <p>Solo guarda texto y llamadas a herramientas. El razonamiento del modelo
 * nunca entra aqui.
 *
 * @param tipo          rol del mensaje
 * @param texto         contenido; puede ser null si el mensaje solo trae llamadas
 * @param toolCalls     llamadas a herramientas de un mensaje del asistente
 * @param toolResponses resultados de herramientas de un mensaje TOOL
 */
public record MensajeMemoria(TipoMensaje tipo, String texto,
                             List<LlamadaHerramienta> toolCalls,
                             List<RespuestaHerramienta> toolResponses) {

    public MensajeMemoria {
        toolCalls = toolCalls == null ? List.of() : List.copyOf(toolCalls);
        toolResponses = toolResponses == null ? List.of() : List.copyOf(toolResponses);
    }

    public enum TipoMensaje { USER, ASSISTANT, SYSTEM, TOOL }

    public record LlamadaHerramienta(String id, String name, String arguments) {
    }

    public record RespuestaHerramienta(String id, String name, String responseData) {
    }
}
