package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import org.junit.jupiter.api.Test;
import org.springframework.ai.chat.messages.AssistantMessage;
import org.springframework.ai.chat.messages.Message;
import org.springframework.ai.chat.messages.ToolResponseMessage;
import org.springframework.ai.chat.messages.UserMessage;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

class PromptTurnoHistorialTest {

    @Test
    void unaVentanaRecortadaNoEmpiezaEnUnaRespuestaDeHerramientaSinSuLlamada() {
        Message huerfana = ToolResponseMessage.builder()
                .responses(List.of(new ToolResponseMessage.ToolResponse("inv-1", "actividad_detalle", "OK")))
                .build();
        Message usuario = new UserMessage("hola");
        Message asistente = new AssistantMessage("buenas");

        assertThat(PromptTurno.desdeElPrimerUsuario(List.of(huerfana, new AssistantMessage("Son 15."), usuario,
                asistente))).containsExactly(usuario, asistente);
        assertThat(PromptTurno.desdeElPrimerUsuario(List.of(usuario, asistente))).containsExactly(usuario, asistente);
        assertThat(PromptTurno.desdeElPrimerUsuario(List.of(huerfana))).isEmpty();
    }
}
