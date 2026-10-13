package com.co.eurekatic.aicontrol.config.agente;

import com.co.eurekatic.aicontrol.agente.memoria.redis.RedisChatMemoryRepository;
import org.springframework.ai.chat.memory.ChatMemory;
import org.springframework.ai.chat.memory.MessageWindowChatMemory;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Memoria de conversacion del agente. La ventana es lo que ve el modelo; el
 * historial completo queda en {@code ai.mensaje}.
 */
@Configuration
public class MemoriaConfig {

    @Bean
    public ChatMemory chatMemory(RedisChatMemoryRepository repositorio, AgenteProperties props) {
        return MessageWindowChatMemory.builder()
                .chatMemoryRepository(repositorio)
                .maxMessages(props.memoria().maxMensajes())
                .build();
    }
}
