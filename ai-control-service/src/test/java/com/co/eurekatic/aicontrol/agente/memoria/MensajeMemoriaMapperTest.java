package com.co.eurekatic.aicontrol.agente.memoria;

import com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoria.LlamadaHerramienta;
import com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoria.RespuestaHerramienta;
import com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoria.TipoMensaje;
import org.junit.jupiter.api.Test;
import org.springframework.ai.chat.messages.AssistantMessage;
import org.springframework.ai.chat.messages.Message;
import org.springframework.ai.chat.messages.SystemMessage;
import org.springframework.ai.chat.messages.ToolResponseMessage;
import org.springframework.ai.chat.messages.UserMessage;

import java.util.List;

import static com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoriaMapper.a;
import static com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoriaMapper.desde;
import static org.assertj.core.api.Assertions.assertThat;

class MensajeMemoriaMapperTest {

    @Test
    void usuarioIdaYVuelta() {
        MensajeMemoria dto = new MensajeMemoria(TipoMensaje.USER, "¿Cómo va Sofía?", null, null);

        Message m = a(dto);

        assertThat(m).isInstanceOf(UserMessage.class);
        assertThat(desde(m)).isEqualTo(dto);
    }

    @Test
    void sistemaIdaYVuelta() {
        MensajeMemoria dto = new MensajeMemoria(TipoMensaje.SYSTEM, "Eres un asistente.", null, null);

        Message m = a(dto);

        assertThat(m).isInstanceOf(SystemMessage.class);
        assertThat(desde(m)).isEqualTo(dto);
    }

    @Test
    void asistenteConLlamadasIdaYVuelta() {
        MensajeMemoria dto = new MensajeMemoria(TipoMensaje.ASSISTANT, "Lo busco.",
                List.of(new LlamadaHerramienta("call-1", "consultar_notas", "{\"PARAM.ID\":7}")), null);

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
        MensajeMemoria dto = new MensajeMemoria(TipoMensaje.TOOL, null, null,
                List.of(new RespuestaHerramienta("call-1", "consultar_notas", "{\"rows\":[]}")));

        Message m = a(dto);

        assertThat(m).isInstanceOf(ToolResponseMessage.class);
        assertThat(((ToolResponseMessage) m).getResponses()).singleElement().satisfies(r -> {
            assertThat(r.id()).isEqualTo("call-1");
            assertThat(r.responseData()).isEqualTo("{\"rows\":[]}");
        });
        assertThat(desde(m)).isEqualTo(dto);
    }

    @Test
    void listasNulasSeNormalizanAVacias() {
        MensajeMemoria dto = new MensajeMemoria(TipoMensaje.USER, "hola", null, null);

        assertThat(dto.toolCalls()).isEmpty();
        assertThat(dto.toolResponses()).isEmpty();
    }
}
