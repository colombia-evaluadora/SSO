package com.example.cdc.capture;

import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.ClickHouseContainer;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.containers.RabbitMQContainer;
import org.testcontainers.utility.DockerImageName;

@SpringBootTest
public abstract class AbstractCaptureIT {

    static PostgreSQLContainer<?> PG = new PostgreSQLContainer<>(
            DockerImageName.parse("debezium/postgres:16-alpine"))
            .withCommand("postgres", "-c", "wal_level=logical");

    static RabbitMQContainer RABBIT = new RabbitMQContainer("rabbitmq:3.13-management-alpine");

    static {
        PG.start();
        RABBIT.start();
    }

    @DynamicPropertySource
    static void props(DynamicPropertyRegistry r) {
        r.add("cdc.postgres.url", () -> "jdbc:postgresql://" + PG.getHost() + ":" + PG.getFirstMappedPort() + "/academico");
        r.add("cdc.postgres.user", PG::getUsername);
        r.add("cdc.postgres.password", PG::getPassword);
        r.add("cdc.amqp.host", RABBIT::getHost);
        r.add("cdc.amqp.port", RABBIT::getFirstMappedPort);
        r.add("cdc.amqp.user", RABBIT::getAdminUsername);
        r.add("cdc.amqp.password", RABBIT::getAdminPassword);
    }
}
