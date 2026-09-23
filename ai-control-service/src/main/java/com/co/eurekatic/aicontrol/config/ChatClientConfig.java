package com.co.eurekatic.aicontrol.config;

import org.springframework.ai.chat.client.ChatClient;
import org.springframework.ai.chat.client.advisor.SimpleLoggerAdvisor;
import org.springframework.ai.openai.OpenAiChatOptions;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import tools.jackson.core.type.TypeReference;
import tools.jackson.databind.json.JsonMapper;

import java.util.Map;

/**
 * El {@link ChatClient} compartido por todos los endpoints de IA.
 *
 * <p>Modelo, temperatura, top-p y max-tokens llegan del autoconfig de
 * {@code spring.ai.openai.chat.*}. Aca solo se agrega lo que no se puede
 * expresar bien en el yml: el {@code extra_body} del proveedor, parseado
 * como JSON para conservar los tipos (ver {@link AiProperties#extraBodyJson()}).
 */
@Configuration
public class ChatClientConfig {

    @Bean
    public ChatClient chatClient(ChatClient.Builder builder, AiProperties props, JsonMapper json) {
        Map<String, Object> extraBody = parseExtraBody(props.extraBodyJson(), json);
        if (!extraBody.isEmpty()) {
            builder.defaultOptions(OpenAiChatOptions.builder().extraBody(extraBody));
        }
        // SimpleLoggerAdvisor solo escribe en DEBUG. Queda apagado por defecto
        // porque el prompt lleva observaciones de menores.
        return builder.defaultAdvisors(new SimpleLoggerAdvisor()).build();
    }

    static Map<String, Object> parseExtraBody(String raw, JsonMapper json) {
        if (raw == null || raw.isBlank()) {
            return Map.of();
        }
        try {
            return json.readValue(raw, new TypeReference<Map<String, Object>>() {});
        } catch (RuntimeException e) {
            throw new IllegalStateException(
                    "sso.ai.extra-body-json (AI_EXTRA_BODY_JSON) no es un objeto JSON valido: " + raw, e);
        }
    }
}
