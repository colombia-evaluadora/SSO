package com.example.cdc.capture;

import io.debezium.engine.ChangeEvent;
import io.debezium.engine.DebeziumEngine;
import io.debezium.engine.format.Json;
import jakarta.annotation.PostConstruct;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.DisposableBean;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.CommandLineRunner;
import org.springframework.stereotype.Component;

import java.io.File;
import java.util.Properties;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

@Component
public class CaptureRunner implements CommandLineRunner, DisposableBean {

    private static final Logger log = LoggerFactory.getLogger(CaptureRunner.class);

    private final DebeziumEngineConfig engineConfig;
    private final AmqpPublisher consumer;
    private final SnapshotRecoveryService snapshotRecovery;

    @Value("${cdc.postgres.url}") private String pgUrl;
    @Value("${cdc.postgres.user}") private String pgUser;
    @Value("${cdc.postgres.password}") private String pgPassword;
    @Value("${cdc.postgres.dbname}") private String pgDbname;
    @Value("${cdc.postgres.publication}") private String publication;
    @Value("${cdc.postgres.slot}") private String slot;
    @Value("${cdc.offsets.dir}") private String offsetsDir;

    private ExecutorService executor;
    private DebeziumEngine<ChangeEvent<String, String>> engine;

    public CaptureRunner(DebeziumEngineConfig engineConfig, AmqpPublisher consumer,
                         SnapshotRecoveryService snapshotRecovery) {
        this.engineConfig = engineConfig;
        this.consumer = consumer;
        this.snapshotRecovery = snapshotRecovery;
    }

    @PostConstruct
    public void prepare() {
        File dir = new File(offsetsDir);
        if (!dir.exists() && !dir.mkdirs()) {
            throw new RuntimeException("No se pudo crear directorio de offsets: " + offsetsDir);
        }
        snapshotRecovery.run();

        File offsetsFile = new File(dir, "offsets.dat");

        Properties props = engineConfig.connectorProperties(pgUrl, pgUser, pgPassword, pgDbname, publication, slot);
        props.setProperty("offset.storage.file.filename", offsetsFile.getAbsolutePath());

        engine = DebeziumEngine.create(Json.class)
                .using(props)
                .notifying(consumer)
                .using((success, message, error) -> {
                    if (error != null) {
                        log.error("Debezium error: {}", message, error);
                    } else if (success) {
                        log.info("Debezium engine arrancado");
                    } else {
                        log.warn("Debezium detenido: {}", message);
                    }
                })
                .build();

        executor = Executors.newSingleThreadExecutor(r -> {
            Thread t = new Thread(r, "cdc-capture-debezium");
            t.setDaemon(false);
            return t;
        });
    }

    @Override
    public void run(String... args) {
        executor.execute(engine);
        log.info("cdc-capture engine arrancado, esperando eventos del slot {}", slot);
    }

    @Override
    public void destroy() throws Exception {
        log.info("Deteniendo cdc-capture engine");
        if (engine != null) {
            try {
                engine.close();
            } catch (Exception e) {
                log.warn("Error cerrando engine", e);
            }
        }
        if (executor != null) {
            executor.shutdown();
        }
    }
}
