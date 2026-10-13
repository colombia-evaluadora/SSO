package com.co.eurekatic.aicontrol.agente.memoria;

import com.co.eurekatic.aicontrol.agente.comun.DatosDelUsuario;
import com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoria.Asistente;
import com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoria.LlamadaHerramienta;
import com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoria.ResultadoHerramienta;
import com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoria.RespuestaHerramienta;
import com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoria.Sistema;
import com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoria.Usuario;
import com.co.eurekatic.aicontrol.agente.persistencia.mensaje.MensajeStore;
import org.springframework.ai.chat.messages.AssistantMessage;
import org.springframework.ai.chat.messages.Message;
import org.springframework.ai.chat.messages.SystemMessage;
import org.springframework.ai.chat.messages.ToolResponseMessage;
import org.springframework.ai.chat.messages.UserMessage;

import java.util.List;

/**
 * Conversion entre los mensajes de Spring AI y {@link MensajeMemoria}, y desde
 * las filas de {@code ai.mensaje}. Pura: sin estado ni I/O.
 */
public final class MensajeMemoriaMapper {

    /** Tipo que Spring AI asigna a todas las llamadas a herramientas de este servicio. */
    private static final String TIPO_LLAMADA = "function";

    private MensajeMemoriaMapper() {
    }

    /**
     * @throws IllegalArgumentException si el mensaje no es de un tipo que la memoria
     *                                  sabe guardar; no se descarta en silencio
     */
    public static MensajeMemoria desde(Message m) {
        return switch (m) {
            case UserMessage u -> new Usuario(u.getText());
            case SystemMessage s -> new Sistema(s.getText());
            case AssistantMessage a -> new Asistente(a.getText(), a.getToolCalls().stream()
                    .map(c -> new LlamadaHerramienta(c.id(), c.name(), c.arguments()))
                    .toList());
            case ToolResponseMessage t -> new RespuestaHerramienta(t.getResponses().stream()
                    .map(r -> new ResultadoHerramienta(r.id(), r.name(), r.responseData()))
                    .toList());
            default -> throw new IllegalArgumentException(
                    "Tipo de mensaje no soportado en la memoria: " + m.getMessageType());
        };
    }

    /** Mensaje de Spring AI listo para el modelo. */
    public static Message a(MensajeMemoria d) {
        return switch (d) {
            case Usuario u -> new UserMessage(u.texto());
            case Sistema s -> new SystemMessage(s.texto());
            case Asistente a -> AssistantMessage.builder()
                    .content(a.texto())
                    .toolCalls(a.toolCalls().stream()
                            .map(c -> new AssistantMessage.ToolCall(c.id(), TIPO_LLAMADA, c.name(), c.arguments()))
                            .toList())
                    .build();
            case RespuestaHerramienta r -> ToolResponseMessage.builder()
                    .responses(r.toolResponses().stream()
                            .map(x -> new ToolResponseMessage.ToolResponse(x.id(), x.name(), x.responseData()))
                            .toList())
                    .build();
        };
    }

    /**
     * Turno de texto desde la base. La ventana de memoria solo guarda USER y
     * ASSISTANT: cualquier otro rol es un error de quien llama.
     *
     * @throws IllegalStateException si la fila no es un turno de texto
     */
    public static MensajeMemoria desdeTurno(MensajeStore.Mensaje fila) {
        return switch (fila.rol()) {
            // Igual que en el turno: el mensaje de la persona vuelve al modelo dentro de su bloque de datos.
            case USER -> new Usuario(DatosDelUsuario.mensaje(fila.contenido()));
            case ASSISTANT -> new Asistente(fila.contenido(), List.of());
            case TOOL, SYSTEM -> throw new IllegalStateException(
                    "La memoria de respaldo solo admite turnos de texto, no " + fila.rol());
        };
    }
}
