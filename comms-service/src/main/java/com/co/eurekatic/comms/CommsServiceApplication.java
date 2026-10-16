package com.co.eurekatic.comms;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.ConfigurationPropertiesScan;
import org.springframework.scheduling.annotation.EnableScheduling;

/**
 * comms-service: gateway de tiempo real (OpenSpec add-tiempo-real-gateway) y
 * chat (add-comunicaciones-mensajeria-mvp). Escrituras por REST; el WebSocket
 * solo difunde (D-1.6). Fan-out entre replicas por Redis pub/sub.
 */
@SpringBootApplication
@EnableScheduling
@ConfigurationPropertiesScan
public class CommsServiceApplication {

    public static void main(String[] args) {
        SpringApplication.run(CommsServiceApplication.class, args);
    }
}
