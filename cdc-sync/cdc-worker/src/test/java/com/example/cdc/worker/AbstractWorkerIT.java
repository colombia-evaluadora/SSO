package com.example.cdc.worker;

import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.ClickHouseContainer;
import org.testcontainers.containers.RabbitMQContainer;
import org.testcontainers.oracle.OracleContainer;
import org.testcontainers.utility.DockerImageName;

@SpringBootTest
public abstract class AbstractWorkerIT {

    static RabbitMQContainer RABBIT = new RabbitMQContainer("rabbitmq:3.13-management-alpine");
    // ClickHouseContainer.beforeContainerDefensiveInit on the version we pull
    // does not implement withUsername() (UnsupportedOperationException at
    // <clinit> time); set credentials via environment variables instead.
    // ClickHouse ships with the `default` user and an open auth policy by
    // default — we override with CLICKHOUSE_USER / CLICKHOUSE_PASSWORD to
    // a known credential pair.
    static ClickHouseContainer CLICKHOUSE = new ClickHouseContainer("clickhouse/clickhouse-server:24.8-alpine")
            .withEnv("CLICKHOUSE_USER", "default")
            .withEnv("CLICKHOUSE_PASSWORD", "demopass");
    static OracleContainer ORACLE = new OracleContainer(DockerImageName.parse("gvenzl/oracle-free:23-slim"))
            .withUsername("academico").withPassword("Academico123");

    static {
        RABBIT.start();
        CLICKHOUSE.start();
        ORACLE.start();
    }

    @DynamicPropertySource
    static void props(DynamicPropertyRegistry r) {
        r.add("cdc.amqp.host", RABBIT::getHost);
        r.add("cdc.amqp.port", RABBIT::getFirstMappedPort);
        r.add("cdc.amqp.user", RABBIT::getAdminUsername);
        r.add("cdc.amqp.password", RABBIT::getAdminPassword);
        r.add("cdc.clickhouse.url", () -> "http://" + CLICKHOUSE.getHost() + ":" + CLICKHOUSE.getFirstMappedPort() + "/auditoria");
        r.add("cdc.oracle.url", ORACLE::getJdbcUrl);
        r.add("cdc.oracle.user", ORACLE::getUsername);
        r.add("cdc.oracle.password", ORACLE::getPassword);
    }
}
