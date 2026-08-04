package com.example.cdc.capture;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.io.File;

@Component
public class SnapshotRecoveryService {

    private static final Logger log = LoggerFactory.getLogger(SnapshotRecoveryService.class);

    @Value("${cdc.offsets.dir}") private String offsetsDir;
    @Value("${cdc.force.snapshot:false}") private boolean forceSnapshot;

    /**
     * Removes stale Debezium offsets when a full snapshot was requested.
     * CaptureRunner invokes this before constructing the Debezium engine.
     */
    public void run() {
        File offsetsFile = new File(offsetsDir, "offsets.dat");
        if (forceSnapshot && offsetsFile.exists()) {
            log.warn("CDC_FORCE_SNAPSHOT=true — eliminando offsets y forzando snapshot completo");
            if (!offsetsFile.delete()) {
                log.error("No se pudo eliminar offsets.dat");
            }
        }
    }
}
