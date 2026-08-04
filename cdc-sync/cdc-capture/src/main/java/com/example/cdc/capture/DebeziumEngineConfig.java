package com.example.cdc.capture;

import org.springframework.context.annotation.Configuration;

import java.util.Properties;

@Configuration
public class DebeziumEngineConfig {

    public Properties connectorProperties(
            String jdbcUrl, String user, String password,
            String dbname, String publication, String slot) {

        Properties props = new Properties();
        props.setProperty("name", "cdc-capture-engine");
        props.setProperty("topic.prefix", "cdc.academico");
        props.setProperty("connector.class", "io.debezium.connector.postgresql.PostgresConnector");
        props.setProperty("database.hostname", extractHost(jdbcUrl));
        props.setProperty("database.port", extractPort(jdbcUrl));
        props.setProperty("database.user", user);
        props.setProperty("database.password", password);
        props.setProperty("database.dbname", dbname);
        props.setProperty("plugin.name", "pgoutput");
        props.setProperty("publication.name", publication);
        props.setProperty("slot.name", slot);
        props.setProperty("snapshot.mode", "initial");
        props.setProperty("heartbeat.interval.ms", "5000");
        props.setProperty("tombstones.on.delete", "false");
        props.setProperty("decimal.handling.mode", "precise");
        props.setProperty("time.precision.mode", "connect");
        props.setProperty("offset.storage", "org.apache.kafka.connect.storage.FileOffsetBackingStore");
        // offset.storage.file.filename is set by CaptureRunner.prepare() with the absolute path
        // derived from ${cdc.offsets.dir} — do NOT hardcode it here (would shadow config).
        props.setProperty("offset.flush.interval.ms", "1000");
        // Disable Kafka Connect schema envelope in the JSON output. By default the engine
        // wraps each record as {"schema":{...},"payload":{op,after,source,ts_ms}}, which
        // AmqpPublisher.handleBatch doesn't unwrap — `event.get("source")` returns null,
        // the publish is silently skipped, and offsets advance with no message reaching
        // RabbitMQ. With schemas.enable=false the value is the bare envelope
        // {op,after,source,ts_ms} we wrap into our own {payload,routing_key,context}.
        props.setProperty("key.converter.schemas.enable", "false");
        props.setProperty("value.converter.schemas.enable", "false");
        return props;
    }

    private String extractHost(String jdbcUrl) {
        // jdbc:postgresql://host:port/dbname
        String stripped = jdbcUrl.replace("jdbc:postgresql://", "");
        return stripped.split(":")[0];
    }

    private String extractPort(String jdbcUrl) {
        String stripped = jdbcUrl.replace("jdbc:postgresql://", "");
        String[] parts = stripped.split(":");
        return parts[1].split("/")[0];
    }
}
