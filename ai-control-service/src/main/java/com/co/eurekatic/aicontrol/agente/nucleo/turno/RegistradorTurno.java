package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoriaMapper;
import com.co.eurekatic.aicontrol.agente.memoria.NotaDeMemoria;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import com.co.eurekatic.aicontrol.agente.persistencia.herramienta.ToolInvocacionStore;
import com.co.eurekatic.aicontrol.agente.persistencia.mensaje.MensajeStore;
import com.co.eurekatic.aicontrol.agente.persistencia.mensaje.MensajeStore.NuevoMensaje;
import com.co.eurekatic.aicontrol.agente.persistencia.mensaje.RolMensaje;
import org.springframework.ai.chat.memory.ChatMemory;
import org.springframework.ai.chat.messages.AssistantMessage;
import org.springframework.ai.chat.messages.Message;
import org.springframework.ai.chat.messages.UserMessage;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * Persistencia y memoria de un turno: el mensaje del usuario al empezar; al terminar, las llamadas a
 * herramientas del turno (como las guardo {@code ai.tool_invocacion}) y la respuesta. El historial completo
 * queda en {@code ai.mensaje} y {@code ai.tool_invocacion}.
 */
@Component
public class RegistradorTurno {

    private final ChatMemory memoria;
    private final MensajeStore mensajes;
    private final ToolInvocacionStore invocaciones;

    public RegistradorTurno(ChatMemory memoria, MensajeStore mensajes, ToolInvocacionStore invocaciones) {
        this.memoria = memoria;
        this.mensajes = mensajes;
        this.invocaciones = invocaciones;
    }

    /**
     * Guarda el mensaje del usuario y lo anade a la memoria. Devuelve la ventana previa al mensaje,
     * que es lo que el modelo debe ver antes de el.
     *
     * @param textoNormalizado mensaje ya pasado por el firewall
     */
    public Inicio iniciar(UUID conversacionId, String textoNormalizado) {
        String clave = conversacionId.toString();
        List<Message> historial = memoria.get(clave);
        // A la memoria antes que a la base: si Redis esta vacio, add la reconstruye desde ai.mensaje y, con el
        // mensaje ya insertado, lo tendria dos veces.
        memoria.add(clave, new UserMessage(PromptTurno.bloqueUsuario(textoNormalizado)));
        long mensajeId = mensajes.insertar(conversacionId,
                new NuevoMensaje(RolMensaje.USER, textoNormalizado, null, null, null, null, null, null, null));
        return new Inicio(mensajeId, historial);
    }

    /** Guarda la respuesta del asistente y su consumo, y la anade a la memoria. Sin llamadas a herramientas. */
    public void registrar(UUID conversacionId, RespuestaAgente respuesta, Consumo consumo) {
        registrar(conversacionId, respuesta, consumo, SIN_MENSAJE);
    }

    /** Un turno sin mensaje del usuario propio: el resultado de confirmar o cancelar una accion. */
    static final long SIN_MENSAJE = -1L;

    /**
     * Igual, poniendo antes en la memoria las llamadas a herramientas que colgaron del mensaje del usuario: sin
     * ellas el modelo solo ve respuestas de texto y aprende a contar consultas en vez de hacerlas.
     *
     * @param mensajeIdUsuario mensaje del turno ({@link Inicio#mensajeId()}); {@link #SIN_MENSAJE} si no hay
     */
    public void registrar(UUID conversacionId, RespuestaAgente respuesta, Consumo consumo, long mensajeIdUsuario) {
        Uso uso = consumo.uso();
        boolean conModelo = !consumo.modelo().isBlank();
        mensajes.insertar(conversacionId, new NuevoMensaje(
                RolMensaje.ASSISTANT,
                respuesta.texto(),
                respuesta.tipo().name(),
                null,
                conModelo ? consumo.modelo() : null,
                uso.tokensEntrada().orElse(null),
                uso.tokensSalida().orElse(null),
                null,
                conModelo ? (int) consumo.latenciaMs() : null));
        List<Message> turno = new ArrayList<>(llamadasDelTurno(conversacionId, mensajeIdUsuario));
        turno.add(new AssistantMessage(NotaDeMemoria.para(respuesta.tipo().name(), textoParaMemoria(respuesta))));
        memoria.add(conversacionId.toString(), turno);
    }

    private List<Message> llamadasDelTurno(UUID conversacionId, long mensajeIdUsuario) {
        if (mensajeIdUsuario == SIN_MENSAJE) {
            return List.of();
        }
        return MensajeMemoriaMapper.llamadas(invocaciones.listarPorConversacion(conversacionId).stream()
                .filter(i -> i.mensajeId() == mensajeIdUsuario)
                .toList());
    }

    /**
     * Todo lo que la persona escribio en la conversacion, incluido el mensaje del turno (ya guardado al iniciar):
     * "deja solo a Brayan y a Luis" y despues "usa los valores por defecto". Con el mensaje actual solo, los
     * nombres y los ids de los anteriores se pierden; la ventana de memoria tambien los recorta.
     */
    public String dichoPorLaPersona(UUID conversacionId) {
        return mensajes.listar(conversacionId).stream()
                .filter(m -> m.rol() == RolMensaje.USER)
                .map(MensajeStore.Mensaje::contenido)
                .collect(Collectors.joining("\n"));
    }

    /** Una pregunta vuelve con lo que pregunto: su texto ("Para continuar necesito estos datos") no lo dice. */
    static String textoParaMemoria(RespuestaAgente respuesta) {
        return respuesta instanceof RespuestaAgente.Pregunta pregunta && !pregunta.faltantes().isEmpty()
                ? pregunta.faltantes().stream()
                        .map(f -> f.campo() + ": " + f.pregunta()
                                + (f.opciones().isEmpty() ? "" : " (opciones: " + String.join(", ", f.opciones()) + ")"))
                        .collect(Collectors.joining("; "))
                : respuesta.texto();
    }

    /**
     * @param mensajeId id del mensaje del usuario ya guardado; las invocaciones cuelgan de el
     * @param historial ventana de la conversacion antes del mensaje actual
     */
    public record Inicio(long mensajeId, List<Message> historial) {

        public Inicio {
            historial = List.copyOf(historial);
        }
    }
}
