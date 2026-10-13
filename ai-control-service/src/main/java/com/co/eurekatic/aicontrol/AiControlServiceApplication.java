package com.co.eurekatic.aicontrol;

import com.co.eurekatic.aicontrol.config.agente.AgenteProperties;
import com.co.eurekatic.aicontrol.config.ia.AiProperties;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.cloud.client.discovery.EnableDiscoveryClient;

/**
 * Endpoints de IA del ecosistema.
 *
 * <p>El modelo se consume por Spring AI contra cualquier API compatible con
 * OpenAI (MiniMax por defecto). Los datos academicos se leen y se guardan a
 * traves del query-service con el JWT del llamante, asi que cada lectura y
 * cada escritura pasan por el mismo gate PL/pgSQL que la pantalla. La base
 * solo guarda el historial del agente, en el schema ai.
 */
@SpringBootApplication
@EnableDiscoveryClient
@EnableConfigurationProperties({AiProperties.class, AgenteProperties.class})
public class AiControlServiceApplication {

    public static void main(String[] args) {
        SpringApplication.run(AiControlServiceApplication.class, args);
    }
}
