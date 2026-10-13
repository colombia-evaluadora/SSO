package com.co.eurekatic.aicontrol.agente.memoria;

import com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoria.Asistente;
import com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoria.LlamadaHerramienta;
import com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoria.RespuestaHerramienta;
import com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoria.ResultadoHerramienta;
import com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoria.Sistema;
import com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoria.Usuario;
import com.co.eurekatic.aicontrol.agente.persistencia.MensajeStore;
import com.co.eurekatic.aicontrol.agente.persistencia.RolMensaje;
import org.junit.jupiter.api.Test;
import org.springframework.ai.chat.messages.AssistantMessage;
import org.springframework.ai.chat.messages.Message;
import org.springframework.ai.chat.messages.SystemMessage;
import org.springframework.ai.chat.messages.ToolResponseMessage;
import org.springframework.ai.chat.messages.UserMessage;

import java.util.List;
import java.util.UUID;

import static com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoriaMapper.a;
import static com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoriaMapper.desde;
import static com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoriaMapper.desdeTurno;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class MensajeMemoriaMapperTest {

    @Test
    void usuarioIdaYVuelta() {
        Usuario dto = new Usuario("¿Cómo va Sofía?");

        Message m = a(dto);

        assertThat(m).isInstanceOf(UserMessage.class);
        assertThat(desde(m)).isEqualTo(dto);
    }

    @Test
    void sistemaIdaYVuelta() {
        Sistema dto = new Sistema("Eres un asistente.");

        Message m = a(dto);

        assertThat(m).isInstanceOf(SystemMessage.class);
        assertThat(desde(m)).isEqualTo(dto);
    }

    @Test
    void asistenteConLlamadasIdaYVuelta() {
        Asistente dto = new Asistente("Lo busco.",
                List.of(new LlamadaHerramienta("call-1", "consultar_notas", "{\"PARAM.ID\":7}")));

        Message m = a(dto);

        assertThat(m).isInstanceOf(AssistantMessage.class);
        AssistantMessage am = (AssistantMessage) m;
        assertThat(am.hasToolCalls()).isTrue();
        assertThat(am.getToolCalls()).singleElement().satisfies(c -> {
            assertThat(c.id()).isEqualTo("call-1");
            assertThat(c.name()).isEqualTo("consultar_notas");
            assertThat(c.arguments()).isEqualTo("{\"PARAM.ID\":7}");
        });
        assertThat(desde(m)).isEqualTo(dto);
    }

    @Test
    void respuestaDeHerramientaIdaYVuelta() {
        RespuestaHerramienta dto = new RespuestaHerramienta(
                List.of(new ResultadoHerramienta("call-1", "consultar_notas", "{\"rows\":[]}")));

        Message m = a(dto);

        assertThat(m).isInstanceOf(ToolResponseMessage.class);
        assertThat(((ToolResponseMessage) m).getResponses()).singleElement().satisfies(r -> {
            assertThat(r.id()).isEqualTo("call-1");
            assertThat(r.responseData()).isEqualTo("{\"rows\":[]}");
        });
        assertThat(desde(m)).isEqualTo(dto);
    }

    @Test
    void textoAusenteSeNormalizaAVacioYListasNulasAVacias() {
        assertThat(new Usuario(null).texto()).isEmpty();
        assertThat(new Asistente(null, null).texto()).isEmpty();
        assertThat(new Asistente(null, null).toolCalls()).isEmpty();
        assertThat(new RespuestaHerramienta(null).toolResponses()).isEmpty();
    }

    @Test
    void unTurnoDeTextoDeLaBaseSeConvierteSinLlamadas() {
        UUID id = UUID.randomUUID();
        MensajeStore.Mensaje fila = new MensajeStore.Mensaje(1L, id, 2, RolMensaje.ASSISTANT, "buenas",
                "RESPUESTA", null, null);

        assertThat(desdeTurno(fila)).isEqualTo(new Asistente("buenas", List.of()));
    }

    @Test
    void unRolQueNoEsDeTextoNoSeReconstruyeDesdeLaBase() {
        MensajeStore.Mensaje fila = new MensajeStore.Mensaje(1L, UUID.randomUUID(), 1, RolMensaje.TOOL,
                null, null, null, null);

        assertThatThrownBy(() -> desdeTurno(fila)).isInstanceOf(IllegalStateException.class);
    }
}
