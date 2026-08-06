package com.example.cdc.common.transform;

import com.example.cdc.common.event.CdcEvent;
import com.example.cdc.common.event.CdcEventFixture;
import com.example.cdc.common.snapshot.SnapshotCache;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class TSedeUsuarioPkTransformerTest {

    private TSedeUsuarioPkTransformer tx;
    private SnapshotCache.SedeUsuarioRow row;

    @BeforeEach
    void setUp() {
        row = new SnapshotCache.SedeUsuarioRow(10L, 5L, 99L, "JORNADA", 1);
        SnapshotCache cache = new SnapshotCache(
                Map.of(),
                Map.of(),
                Map.of(1L, row),
                Map.of(),
                Map.of(),
                Map.of("JORNADA", 50L),
                Map.of(),
                Map.of()
        );
        tx = new TSedeUsuarioPkTransformer(cache);
    }

    @Test
    void composesOraclePkFromSnapshot() {
        CdcEvent ev = CdcEventFixture.createInsert("tsede_usuario",
                Map.of(
                        "pk_tsede_usuario", 1,
                        "fk_tsede", 10,
                        "fk_trol", 5,
                        "fk_tusuario", 99,
                        "fk_tlv_jornada", "JORNADA",
                        "orden", 1
                ));
        Map<String, Object> result = tx.apply(ev);

        assertThat(result)
                .containsEntry("FK_TSEDE", 10L)
                .containsEntry("FK_TROL", 5L)
                .containsEntry("FK_TUSUARIO", 99L)
                .containsEntry("FK_TJORNADA", 50L)
                .containsEntry("ORDEN", 1);
    }

    @Test
    void snapshotMissReturnsEmpty() {
        CdcEvent ev = CdcEventFixture.createInsert("tsede_usuario",
                Map.of("pk_tsede_usuario", 999, "fk_tlv_jornada", "JORNADA"));

        Map<String, Object> result = tx.apply(ev);

        assertThat(result).isEmpty();
    }

    @Test
    void jornadaNotInReverseMapLeavesFkNull() {
        SnapshotCache cache = new SnapshotCache(
                Map.of(),
                Map.of(),
                Map.of(1L, row),
                Map.of(),
                Map.of(),
                Map.of(),
                Map.of(),
                Map.of()
        );
        TSedeUsuarioPkTransformer t = new TSedeUsuarioPkTransformer(cache);

        CdcEvent ev = CdcEventFixture.createInsert("tsede_usuario",
                Map.of("pk_tsede_usuario", 1, "fk_tlv_jornada", "OTRA"));

        Map<String, Object> result = t.apply(ev);

        assertThat(result)
                .containsEntry("FK_TSEDE", 10L)
                .containsEntry("FK_TROL", 5L)
                .containsEntry("FK_TUSUARIO", 99L)
                .containsEntry("FK_TJORNADA", null)
                .containsEntry("ORDEN", 1);
    }

    @Test
    void deleteProducesEmptyMap() {
        CdcEvent ev = CdcEventFixture.createDelete("tsede_usuario",
                Map.of("pk_tsede_usuario", 1));

        Map<String, Object> result = tx.apply(ev);

        assertThat(result).isEmpty();
    }
}
