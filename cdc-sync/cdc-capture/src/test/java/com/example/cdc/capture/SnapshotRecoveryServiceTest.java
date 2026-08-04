package com.example.cdc.capture;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.test.util.ReflectionTestUtils;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class SnapshotRecoveryServiceTest {

    @Test
    void removes_offsets_before_engine_start_when_snapshot_is_forced(@TempDir Path tempDir)
            throws Exception {
        Path offsetsFile = tempDir.resolve("offsets.dat");
        Files.writeString(offsetsFile, "stale-offset");
        SnapshotRecoveryService service = new SnapshotRecoveryService();
        ReflectionTestUtils.setField(service, "offsetsDir", tempDir.toString());
        ReflectionTestUtils.setField(service, "forceSnapshot", true);

        service.run();

        assertThat(offsetsFile).doesNotExist();
    }
}
