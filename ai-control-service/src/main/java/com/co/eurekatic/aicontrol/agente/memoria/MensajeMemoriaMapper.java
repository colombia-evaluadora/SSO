package com.co.eurekatic.aicontrol.agente.memoria;

import com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoria.LlamadaHerramienta;
import com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoria.RespuestaHerramienta;
import com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoria.TipoMensaje;
import org.springframework.ai.chat.messages.AssistantMessage;
import org.springframework.ai.chat.messages.Message;
import org.springframework.ai.chat.messages.SystemMessage;
import org.springframework.ai.chat.messages.ToolResponseMessage;
import org.springframework.ai.chat.messages.UserMessage;

import java.util.List;

/**
 * Conversion entre los mensajes de Spring AI y {@link MensajeMemoria}, en
 * los dos sentidos.
 */
public final class MensajeMemoriaMapper {

    /** Tipo que Spring AI asigna a todas las llamadas a herramientas de este servicio. */
    private static final String TIPO_LLAMADA = "function";

    private MensajeMemoriaMapper() {
    }

    /**
     * @throws IllegalArgumentException si el mensaje no es de un tipo que la
     *                                  memoria sabe guardar; no se descarta en silencio
     */
    public static MensajeMemoria desde(Message m) {
        if (m instanceof UserMessage u) {
            return new MensajeMemoria(TipoMensaje.USER, u.getText(), null, null);
        }
        if (m instanceof AssistantMessage a) {
            List<LlamadaHerramienta> llamadas = a.getToolCalls().stream()
                    .map(c -> new LlamadaHerramienta(c.id(), c.name(), c.arguments()))
                    .toList();
            return new MensajeMemoria(TipoMensaje.ASSISTANT, a.getText(), llamadas, null);
        }
        if (m instanceof ToolResponseMessage t) {
            List<RespuestaHerramienta> respuestas = t.getResponses().stream()
                    .map(r -> new RespuestaHerramienta(r.id(), r.name(), r.responseData()))
                    .toList();
            return new MensajeMemoria(TipoMensaje.TOOL, null, null, respuestas);
        }
        if (m instanceof SystemMessage s) {
            return new MensajeMemoria(TipoMensaje.SYSTEM, s.getText(), null, null);
        }
        throw new IllegalArgumentException("Tipo de mensaje no soportado en la memoria: " + m.getMessageType());
    }

    /** Mensaje de Spring AI listo para el modelo. */
    public static Message a(MensajeMemoria d) {
        return switch (d.tipo()) {
            case USER -> new UserMessage(d.texto());
            case SYSTEM -> new SystemMessage(d.texto());
            case ASSISTANT -> AssistantMessage.builder()
                    .content(d.texto())
                    .toolCalls(d.toolCalls().stream()
                            .map(c -> new AssistantMessage.ToolCall(c.id(), TIPO_LLAMADA, c.name(), c.arguments()))
                            .toList())
                    .build();
            case TOOL -> ToolResponseMessage.builder()
                    .responses(d.toolResponses().stream()
                            .map(r -> new ToolResponseMessage.ToolResponse(r.id(), r.name(), r.responseData()))
                            .toList())
                    .build();
        };
    }
}
