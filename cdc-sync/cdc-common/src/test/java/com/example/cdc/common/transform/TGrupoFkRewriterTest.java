package com.example.cdc.common.transform;

import com.example.cdc.common.event.CdcEvent;
import com.example.cdc.common.event.CdcEventFixture;
import com.example.cdc.common.snapshot.SnapshotCache;
import org.junit.jupiter.api.*;
import java.util.*;
import static org.assertj.core.api.Assertions.assertThat;

class TGrupoFkRewriterTest {
    private TGrupoFkRewriter tx;

    @BeforeEach
    void setUp() {
        SnapshotCache cache = new SnapshotCache(Map.of(), Map.of(), Map.of(), Map.of(), Map.of(),
            Map.of("JORNADA_A", 50L), Map.of("MODELO_X", 60L));
        tx = new TGrupoFkRewriter(cache);
    }

    @Test
    void rewritesJornadaAndModeloPedagogicoFks() {
        CdcEvent ev = CdcEventFixture.createInsert("tgrupo",
            Map.of("pk_tgrupo", 1, "fk_tlv_jornada", "JORNADA_A",
                  "fk_tlv_modelo_pedagogico", "MODELO_X", "fk_tplan", 999, "nombre", "A"));
        Map<String, Object> result = tx.apply(ev);
        assertThat(result).containsEntry("FK_TJORNADA", 50L)
            .containsEntry("FK_TMODELO_PEDAGOGICO", 60L)
            .doesNotContainKey("FK_TPLAN")
            .containsEntry("NOMBRE", "A");
    }

    @Test
    void lookupMissLeavesFkNull() {
        CdcEvent ev = CdcEventFixture.createInsert("tgrupo",
            Map.of("pk_tgrupo", 1, "fk_tlv_jornada", "OTRA", "fk_tlv_modelo_pedagogico", "OTRO"));
        Map<String, Object> result = tx.apply(ev);
        assertThat(result).containsEntry("FK_TJORNADA", null)
            .containsEntry("FK_TMODELO_PEDAGOGICO", null);
    }

    @Test
    void dropsFkTplanAlways() {
        CdcEvent ev = CdcEventFixture.createInsert("tgrupo",
            Map.of("pk_tgrupo", 1, "fk_tlv_jornada", "JORNADA_A", "fk_tplan", 999));
        Map<String, Object> result = tx.apply(ev);
        assertThat(result).doesNotContainKey("FK_TPLAN");
    }
}