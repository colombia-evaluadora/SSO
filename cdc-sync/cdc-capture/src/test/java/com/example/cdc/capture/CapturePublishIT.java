package com.example.cdc.capture;

import org.junit.jupiter.api.Test;
import org.springframework.amqp.core.Message;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.springframework.beans.factory.annotation.Autowired;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.Statement;

import static org.assertj.core.api.Assertions.assertThat;
import static org.awaitility.Awaitility.await;
import static java.util.concurrent.TimeUnit.SECONDS;

class CapturePublishIT extends AbstractCaptureIT {

    @Autowired RabbitTemplate rabbitTemplate;
    @Autowired DataSource dataSource;

    @Test
    void insert_in_pg_appears_in_rabbitmq() throws Exception {
        // Init schema mínimo
        try (Connection c = dataSource.getConnection(); Statement s = c.createStatement()) {
            s.execute("CREATE TABLE IF NOT EXISTS clientes (id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY, nombre TEXT NOT NULL)");
            s.execute("ALTER TABLE clientes REPLICA IDENTITY FULL");
            s.execute("CREATE PUBLICATION IF NOT EXISTS cdc_pub FOR TABLE clientes");
        }

        // Insertar
        try (Connection c = dataSource.getConnection(); Statement s = c.createStatement()) {
            s.execute("INSERT INTO clientes (nombre) VALUES ('Alice')");
        }

        // Verificar que llega a RabbitMQ
        await().atMost(30, SECONDS).untilAsserted(() -> {
            Message msg = rabbitTemplate.receive("cdc.worker", 1000);
            assertThat(msg).isNotNull();
            assertThat(new String(msg.getBody())).contains("Alice");
        });
    }
}
