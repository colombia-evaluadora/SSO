package com.co.eurekatic.aicontrol.agente.memoria;

import com.co.eurekatic.aicontrol.agente.comun.DatosDelUsuario;
import com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoria.Asistente;
import com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoria.LlamadaHerramienta;
import com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoria.ResultadoHerramienta;
import com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoria.RespuestaHerramienta;
import com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoria.Sistema;
import com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoria.Usuario;
import com.co.eurekatic.aicontrol.agente.persistencia.herramienta.ToolInvocacionStore;
import com.co.eurekatic.aicontrol.agente.persistencia.mensaje.MensajeStore;
import org.springframework.ai.chat.messages.AssistantMessage;
import org.springframework.ai.chat.messages.Message;
import org.springframework.ai.chat.messages.SystemMessage;
import org.springframework.ai.chat.messages.ToolResponseMessage;
import org.springframework.ai.chat.messages.UserMessage;

import java.util.List;
import java.util.Objects;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

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
     * Las llamadas a herramientas de un turno, como el par que el modelo conoce: un mensaje del asistente que las
     * pide y la respuesta de cada una. Sale de {@code ai.tool_invocacion}, que guarda las claves de los argumentos y
     * un resumen del resultado, nunca los datos: la llamada va sin argumentos (con las claves el modelo copiaria
     * {@code {"claves": [...]}} como forma de llamar) y la respuesta dice que sus datos ya no estan. Vacio si el
     * turno no llamo a ninguna.
     */
    public static List<Message> llamadas(List<ToolInvocacionStore.Invocacion> invocaciones) {
        if (invocaciones.isEmpty()) {
            return List.of();
        }
        List<AssistantMessage.ToolCall> pedidas = invocaciones.stream()
                .map(i -> new AssistantMessage.ToolCall(idDe(i), TIPO_LLAMADA, i.nombre(), "{}"))
                .toList();
        List<ToolResponseMessage.ToolResponse> respuestas = invocaciones.stream()
                .map(i -> new ToolResponseMessage.ToolResponse(idDe(i), i.nombre(),
                        "[Resultado de un turno anterior, sin sus datos: "
                                + Objects.requireNonNullElse(i.resultadoResumen(), "sin resumen")
                                + claves(i.argumentosJson()) + ". Si necesitas el dato, vuelve a llamar.]"))
                .toList();
        return List.of(AssistantMessage.builder().content("").toolCalls(pedidas).build(),
                ToolResponseMessage.builder().responses(respuestas).build());
    }

    private static String idDe(ToolInvocacionStore.Invocacion invocacion) {
        return "inv-" + invocacion.id();
    }

    /** "; argumentos: id, categoria" a partir de {@code {"claves": ["id", "categoria"], ...}}. */
    private static String claves(String argumentosJson) {
        if (argumentosJson == null) {
            return "";
        }
        Matcher m = CLAVES.matcher(argumentosJson);
        if (!m.find() || m.group(1).isBlank()) {
            return "";
        }
        return "; argumentos: " + m.group(1).replace("\"", "").replaceAll("\\s*,\\s*", ", ").strip();
    }

    private static final Pattern CLAVES = Pattern.compile("\"claves\"\\s*:\\s*\\[([^\\]]*)]");

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
            case ASSISTANT -> new Asistente(
                    NotaDeMemoria.para(fila.tipoRespuesta(), fila.contenido(), fila.accionesUi()), List.of());
            case TOOL, SYSTEM -> throw new IllegalStateException(
                    "La memoria de respaldo solo admite turnos de texto, no " + fila.rol());
        };
    }
}
