package com.example.cdc.worker;

import com.example.cdc.common.event.CdcEvent;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.springframework.amqp.core.Message;
import org.springframework.amqp.core.MessageBuilder;
import org.springframework.amqp.core.MessageProperties;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.jdbc.core.JdbcTemplate;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.Statement;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.awaitility.Awaitility.await;
import static java.util.concurrent.TimeUnit.SECONDS;

class WorkerConsumeIT extends AbstractWorkerIT {

    @Autowired RabbitTemplate rabbitTemplate;
    @Autowired JdbcTemplate oracleJdbc;
    @Autowired JdbcTemplate clickhouseJdbc;
    @Autowired DataSource oracleDataSource;

    @Test
    void insert_event_appears_in_clickhouse_and_oracle() throws Exception {
        // Init Oracle schema
        try (Connection c = oracleDataSource.getConnection(); Statement s = c.createStatement()) {
            s.execute("CREATE TABLE CLIENTES (PK_CLIENTE NUMBER(19,0) PRIMARY KEY, NOMBRE VARCHAR2(200) NOT NULL)");
        }

        // Publicar evento simulado en RabbitMQ
        Map<String, Object> payload = Map.of(
                "op", "c",
                "after", Map.of("pk_cliente", 1, "nombre", "Alice"),
                "source", Map.of("schema", "public", "table", "clientes", "lsn", 12345, "txId", 100, "snapshot", "false"),
                "ts_ms", System.currentTimeMillis()
        );
        Message msg = MessageBuilder.withBody(new ObjectMapper().writeValueAsBytes(payload))
                .setContentType("application/json")
                .build();
        rabbitTemplate.convertAndSend("cdc.events", "public.clientes", msg);

        // Verificar ClickHouse
        await().atMost(30, SECONDS).untilAsserted(() -> {
            Integer count = clickhouseJdbc.queryForObject(
                    "SELECT count() FROM auditoria.audit_log WHERE tabla = 'clientes'", Integer.class);
            assertThat(count).isGreaterThanOrEqualTo(1);
        });

        // Verificar Oracle
        await().atMost(30, SECONDS).untilAsserted(() -> {
            Integer count = oracleJdbc.queryForObject(
                    "SELECT COUNT(*) FROM CLIENTES WHERE NOMBRE = 'Alice'", Integer.class);
            assertThat(count).isEqualTo(1);
        });
    }
}
