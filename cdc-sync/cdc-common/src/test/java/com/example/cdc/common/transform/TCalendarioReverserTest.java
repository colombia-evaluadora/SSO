package com.example.cdc.common.transform;

import com.example.cdc.common.event.CdcEvent;
import com.example.cdc.common.event.Operation;
import com.example.cdc.common.snapshot.SnapshotCache;
import org.junit.jupiter.api.Test;

import java.util.Map;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;

class TCalendarioReverserTest {

    private final SnapshotCache cache = new SnapshotCache(
        Map.of(), Map.of(), Map.of(), Map.of(), Map.of(),
        Map.of(), Map.of(), Map.of(),
        Map.of(42L, new SnapshotCache.CalendarioSplit(7L, 9L)));

    @Test
    void splits_fk_tperiodo_academico_into_two_oracle_fks() {
        CdcEvent ev = new CdcEvent(Operation.INSERT, null,
            Map.of("pk_tcalendario", 1, "fk_tperiodo_academico", 42, "nombre", "CAL_X"),
            new CdcEvent.Source("academico", "academico_test", "tcalendario",
                1L, 100L, "false"),
            System.currentTimeMillis(), "academico_test.tcalendario", null, null);
        OperationContext ctx = new OperationContext("tcalendario", "TCALENDARIO",
            "ACADEMICO", "PK_TCALENDARIO", true, false, false);

        TCalendarioReverser r = new TCalendarioReverser(cache);
        Optional<Map<String, Object>> out = r.apply(ev, ctx);

        assertThat(out).isPresent();
        assertThat(out.get().get("FK_TANO_LECTIVO")).isEqualTo(7L);
        assertThat(out.get().get("FK_TSEDE")).isEqualTo(9L);
        assertThat(out.get()).doesNotContainKey("fk_tperiodo_academico");
        assertThat(out.get()).doesNotContainKey("FK_TPERIODO_ACADEMICO");
    }

    @Test
    void snapshot_miss_emits_null_oracle_fks() {
        CdcEvent ev = new CdcEvent(Operation.INSERT, null,
            Map.of("pk_tcalendario", 1, "fk_tperiodo_academico", 9999L),
            new CdcEvent.Source("academico", "academico_test", "tcalendario",
                1L, 100L, "false"),
            System.currentTimeMillis(), "academico_test.tcalendario", null, null);
        OperationContext ctx = new OperationContext("tcalendario", "TCALENDARIO",
            "ACADEMICO", "PK_TCALENDARIO", true, false, false);

        TCalendarioReverser r = new TCalendarioReverser(cache);
        Optional<Map<String, Object>> out = r.apply(ev, ctx);

        assertThat(out).isPresent();
        assertThat(out.get().get("FK_TANO_LECTIVO")).isNull();
        assertThat(out.get().get("FK_TSEDE")).isNull();
    }

    @Test
    void missing_periodo_fk_does_not_throw() {
        CdcEvent ev = new CdcEvent(Operation.INSERT, null,
            Map.of("pk_tcalendario", 1),
            new CdcEvent.Source("academico", "academico_test", "tcalendario",
                1L, 100L, "false"),
            System.currentTimeMillis(), "academico_test.tcalendario", null, null);
        OperationContext ctx = new OperationContext("tcalendario", "TCALENDARIO",
            "ACADEMICO", "PK_TCALENDARIO", true, false, false);

        TCalendarioReverser r = new TCalendarioReverser(cache);
        Optional<Map<String, Object>> out = r.apply(ev, ctx);

        assertThat(out).isPresent();
        assertThat(out.get().get("FK_TANO_LECTIVO")).isNull();
        assertThat(out.get().get("FK_TSEDE")).isNull();
    }
}
