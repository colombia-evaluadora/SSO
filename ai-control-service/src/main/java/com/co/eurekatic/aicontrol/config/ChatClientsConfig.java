package com.co.eurekatic.aicontrol.config;

import org.springframework.ai.chat.client.ChatClient;
import org.springframework.ai.openai.OpenAiChatOptions;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import tools.jackson.databind.json.JsonMapper;

import java.util.Map;

/**
 * Los dos clientes del agente: mismo proveedor, distinto modelo y distinto
 * presupuesto de salida.
 *
 * <p>{@code rapido} clasifica y redacta; {@code razonador} planea y elige
 * herramientas. El {@code chatClient} de resumenes sigue en
 * {@link ChatClientConfig} y es el primario, para que la inyeccion sin
 * calificador no cambie de comportamiento.
 */
@Configuration
public class ChatClientsConfig {

    @Bean
    @Qualifier("rapido")
    public ChatClient rapido(ChatClient.Builder builder, AgenteProperties props, JsonMapper json) {
        return builder.defaultOptions(opciones(props.modeloRapido(), props.extraBodyRapidoJson(),
                props.maxTokensRapido(), json)).build();
    }

    @Bean
    @Qualifier("razonador")
    public ChatClient razonador(ChatClient.Builder builder, AgenteProperties props, JsonMapper json) {
        return builder.defaultOptions(opciones(props.modeloRazonador(), props.extraBodyRazonadorJson(),
                props.maxTokensRazonador(), json)).build();
    }

    /**
     * Opciones por defecto de un cliente. Solo se fijan modelo, tope de tokens
     * y extra_body; temperatura y top-p siguen los de {@code spring.ai.openai.chat}.
     */
    static OpenAiChatOptions.Builder opciones(String modelo, String extraJson, int maxTokens, JsonMapper json) {
        Map<String, Object> extra = ChatClientConfig.parseExtraBody(extraJson, json);
        OpenAiChatOptions.Builder b = OpenAiChatOptions.builder();
        b.model(modelo);
        b.maxTokens(maxTokens);
        b.extraBody(extra);
        return b;
    }
}
