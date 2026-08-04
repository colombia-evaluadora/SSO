package com.example.cdc.capture;

import io.debezium.engine.DebeziumEngine;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;

class DebeziumEngineConfigTest {

    @Test
    void builds_engine_with_pgoutput_and_initial_snapshot() {
        DebeziumEngineConfig config = new DebeziumEngineConfig();
        var props = config.connectorProperties(
            "jdbc:postgresql://localhost:5432/academico",
            "academico", "demopass", "academico",
            "cdc_pub", "cdc_slot"
        );

        assertThat(props.get("connector.class"))
            .isEqualTo("io.debezium.connector.postgresql.PostgresConnector");
        assertThat(props.get("plugin.name")).isEqualTo("pgoutput");
        assertThat(props.get("snapshot.mode")).isEqualTo("initial");
        assertThat(props.get("publication.name")).isEqualTo("cdc_pub");
        assertThat(props.get("slot.name")).isEqualTo("cdc_slot");
    }

    @Test
    void connector_config_is_loadable_with_required_keys() {
        DebeziumEngineConfig config = new DebeziumEngineConfig();
        var props = config.connectorProperties(
            "jdbc:postgresql://localhost:5432/academico",
            "academico", "demopass", "academico",
            "cdc_pub", "cdc_slot"
        );

        // topic.prefix is mandatory in Debezium 3.1.
        assertThat(props.get("topic.prefix")).isEqualTo("cdc.academico");

        // The configured connector class must be on the runtime classpath.
        String connectorClass = (String) props.get("connector.class");
        assertThatCode(() -> Class.forName(connectorClass))
            .doesNotThrowAnyException();

        // Sanity: plugin name keeps the pgoutput contract.
        assertThat(props.get("plugin.name")).isEqualTo("pgoutput");

        // Properties object is non-empty and convertible to Debezium Configuration.
        assertThat(props).isNotEmpty();
        assertThatCode(() -> io.debezium.config.Configuration.from(props))
            .doesNotThrowAnyException();
    }
}
