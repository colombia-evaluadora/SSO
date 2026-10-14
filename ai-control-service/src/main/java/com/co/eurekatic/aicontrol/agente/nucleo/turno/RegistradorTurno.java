package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import com.co.eurekatic.aicontrol.agente.memoria.NotaDeMemoria;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import com.co.eurekatic.aicontrol.agente.persistencia.mensaje.MensajeStore;
import com.co.eurekatic.aicontrol.agente.persistencia.mensaje.MensajeStore.NuevoMensaje;
import com.co.eurekatic.aicontrol.agente.persistencia.mensaje.RolMensaje;
import org.springframework.ai.chat.memory.ChatMemory;
import org.springframework.ai.chat.messages.AssistantMessage;
import org.springframework.ai.chat.messages.Message;
import org.springframework.ai.chat.messages.UserMessage;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.UUID;

/**
 * Persistencia y memoria de un turno: el mensaje del usuario al empezar, la respuesta al terminar.
 * La memoria solo guarda los turnos de texto (USER y ASSISTANT); el historial completo queda en
 * {@code ai.mensaje}.
 */
@Component
public class RegistradorTurno {

    private final ChatMemory memoria;
    private final MensajeStore mensajes;

    public RegistradorTurno(ChatMemory memoria, MensajeStore mensajes) {
        this.memoria = memoria;
        this.mensajes = mensajes;
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
        long mensajeId = mensajes.insertar(conversacionId,
                new NuevoMensaje(RolMensaje.USER, textoNormalizado, null, null, null, null, null, null, null));
        memoria.add(clave, new UserMessage(PromptTurno.bloqueUsuario(textoNormalizado)));
        return new Inicio(mensajeId, historial);
    }

    /** Guarda la respuesta del asistente y su consumo, y la anade a la memoria. */
    public void registrar(UUID conversacionId, RespuestaAgente respuesta, Consumo consumo) {
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
        memoria.add(conversacionId.toString(),
                new AssistantMessage(NotaDeMemoria.para(respuesta.tipo().name(), respuesta.texto())));
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
