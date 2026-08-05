package com.example.cdc.common.transform;

import com.example.cdc.common.event.CdcEvent;
import com.example.cdc.common.event.CdcEventFixture;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.HashMap;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class TEstablecimientoFkCycleTransformerTest {

    private TEstablecimientoFkCycleTransformer tx;

    @BeforeEach
    void setUp() {
        tx = new TEstablecimientoFkCycleTransformer();
    }

    @Test
    void initialMergeEmitsNullFkArchivo() {
        CdcEvent ev = CdcEventFixture.createInsert("testablecimiento",
                Map.of("pk_testablecimiento", 1, "fk_tarchivo", 100, "nombre", "Colegio X"));

        TEstablecimientoFkCycleTransformer.Decision decision = tx.apply(ev);

        assertThat(decision.initialMerge().get("FK_TARCHIVO")).isNull();
        assertThat(decision.initialMerge().get("NOMBRE")).isEqualTo("Colegio X");
        assertThat(decision.pendingUpdates()).containsKey(1L);
        assertThat(decision.pendingUpdates().get(1L)).isEqualTo(100L);
    }

    @Test
    void tarchivoDrainsPendingUpdates() {
        tx.apply(CdcEventFixture.createInsert("testablecimiento",
                Map.of("pk_testablecimiento", 1, "fk_tarchivo", 100, "nombre", "X")));

        TEstablecimientoFkCycleTransformer.Decision decision = tx.apply(
                CdcEventFixture.createInsert("tarchivo",
                        Map.of("pk_tarchivo", 100, "urls3", "s3://...")));

        assertThat(decision.deferredUpdates()).hasSize(1);
        assertThat(decision.deferredUpdates().get(0).pkEstablecimiento()).isEqualTo(1L);
    }

    @Test
    void tsedeProducesSimpleMerge() {
        TEstablecimientoFkCycleTransformer.Decision decision = tx.apply(
                CdcEventFixture.createInsert("tsede", Map.of("pk_tsede", 10, "nombre", "Sede 1")));

        assertThat(decision.initialMerge()).containsEntry("PK_TSEDE", 10L);
        assertThat(decision.deferredUpdates()).isEmpty();
    }

    @Test
    void testablecimientoWithoutFkArchivoNoPendingUpdate() {
        Map<String, Object> row = new HashMap<>();
        row.put("pk_testablecimiento", 2);
        row.put("fk_tarchivo", null);
        row.put("nombre", "Y");
        TEstablecimientoFkCycleTransformer.Decision decision = tx.apply(
                CdcEventFixture.createInsert("testablecimiento", row));

        assertThat(decision.initialMerge().get("FK_TARCHIVO")).isNull();
        assertThat(decision.pendingUpdates()).isEmpty();
    }
}
