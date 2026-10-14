package com.co.eurekatic.aicontrol.config.ia;

import com.co.eurekatic.aicontrol.config.agente.AgenteProperties;
import org.junit.jupiter.api.Test;
import org.springframework.ai.openai.OpenAiChatOptions;
import tools.jackson.databind.json.JsonMapper;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ChatClientsConfigTest {

    private static final JsonMapper JSON = JsonMapper.builder().build();

    @Test
    void rapidoApagaElRazonamiento() {
        OpenAiChatOptions o = ChatClientsConfig
                .opciones(new AgenteProperties.Modelo("MiniMax-M3", "{\"thinking\":{\"type\":\"disabled\"}}", 1500), JSON)
                .build();

        assertThat(o.getModel()).isEqualTo("MiniMax-M3");
        assertThat(o.getMaxTokens()).isEqualTo(1500);
        assertThat(o.getExtraBody()).containsEntry("thinking", Map.of("type", "disabled"));
    }

    @Test
    void razonadorPideAdaptativoYReasoningSplitComoBooleano() {
        OpenAiChatOptions o = ChatClientsConfig
                .opciones(new AgenteProperties.Modelo("MiniMax-M3",
                        "{\"thinking\":{\"type\":\"adaptive\"},\"reasoning_split\":true}", 6000), JSON)
                .build();

        assertThat(o.getMaxTokens()).isEqualTo(6000);
        assertThat(o.getExtraBody()).containsEntry("thinking", Map.of("type", "adaptive"));
        assertThat(o.getExtraBody().get("reasoning_split")).isEqualTo(Boolean.TRUE);
    }

    @Test
    void extraBodyInvalidoFallaAlConstruir() {
        assertThatThrownBy(() -> ChatClientsConfig.opciones(
                        new AgenteProperties.Modelo("MiniMax-M3", "no es json", 1500), JSON))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("AI_EXTRA_BODY_JSON");
    }
}
