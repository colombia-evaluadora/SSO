package com.example.cdc.common.transform;

import com.example.cdc.common.event.CdcEvent;
import com.example.cdc.common.event.Operation;
import com.example.cdc.common.snapshot.SnapshotCache;
import org.junit.jupiter.api.Test;

import java.util.HashMap;
import java.util.Map;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;

class TForeignKeyResolverTest {

    private static final Map<String, Map<String, Long>> INDEX = Map.of(
        "ESTADO", Map.of("ACTIVO", 7L),
        "FORMATO_CALIFICACION", Map.of("NUMERICO", 9L));

    private final SnapshotCache cache = new SnapshotCache(
        Map.of(), Map.of(), Map.of(), Map.of(), Map.of(),
        Map.of(), Map.of(), INDEX);

    @Test
    void resolves_fk_tlv_column_via_categoria_suffix() {
        TForeignKeyResolver r = new TForeignKeyResolver(cache, Map.of());
        Map<String, Object> row = new HashMap<>();
        row.put("pk_t", 1);
        row.put("fk_tlv_estado", "ACTIVO");
        Optional<Map<String, Object>> out = r.apply(event(row), ctx());
        assertThat(out).isPresent();
        assertThat(out.get().get("FK_ESTADO")).isEqualTo(7L);
        assertThat(out.get()).doesNotContainKey("fk_tlv_estado");
        assertThat(out.get()).containsEntry("pk_t", 1);
    }

    @Test
    void honours_overrides_when_categoria_does_not_match_suffix() {
        TForeignKeyResolver r = new TForeignKeyResolver(
            cache, Map.of("FK_TLV_FORMATO_CALIFICACION_ACT", "FORMATO_CALIFICACION"));
        Map<String, Object> row = new HashMap<>();
        row.put("pk_t", 1);
        row.put("fk_tlv_formato_calificacion_act", "NUMERICO");
        Optional<Map<String, Object>> out = r.apply(event(row), ctx());
        assertThat(out).isPresent();
        assertThat(out.get().get("FK_FORMATO_CALIFICACION_ACT")).isEqualTo(9L);
        assertThat(out.get()).doesNotContainKey("fk_tlv_formato_calificacion_act");
    }

    @Test
    void miss_emits_null_oracle_fk() {
        TForeignKeyResolver r = new TForeignKeyResolver(cache, Map.of());
        Map<String, Object> row = new HashMap<>();
        row.put("pk_t", 1);
        row.put("fk_tlv_estado", "DESCONOCIDO");
        Optional<Map<String, Object>> out = r.apply(event(row), ctx());
        assertThat(out).isPresent();
        assertThat(out.get().get("FK_ESTADO")).isNull();
    }

    @Test
    void no_fk_tlv_columns_passes_row_through() {
        TForeignKeyResolver r = new TForeignKeyResolver(cache, Map.of());
        Map<String, Object> row = new HashMap<>();
        row.put("pk_t", 1);
        row.put("nombre", "X");
        Optional<Map<String, Object>> out = r.apply(event(row), ctx());
        assertThat(out).isPresent();
        assertThat(out.get()).containsEntry("nombre", "X").containsEntry("pk_t", 1);
        assertThat(out.get()).doesNotContainKey("FK_NOMBRE");
    }

    @Test
    void numeric_codigo_is_stringified_before_lookup() {
        TForeignKeyResolver r = new TForeignKeyResolver(cache, Map.of());
        Map<String, Object> row = new HashMap<>();
        row.put("pk_t", 1);
        row.put("fk_tlv_estado", 7);  // long, not string
        Optional<Map<String, Object>> out = r.apply(event(row), ctx());
        assertThat(out).isPresent();
        assertThat(out.get().get("FK_ESTADO")).isEqualTo(7L);
    }

    private static CdcEvent event(Map<String, Object> after) {
        return new CdcEvent(Operation.INSERT, null, after,
            new CdcEvent.Source("academico", "academico_test", "tasignatura_plan",
                1L, 100L, "false"),
            System.currentTimeMillis(), "academico_test.tasignatura_plan", null, null);
    }

    private static OperationContext ctx() {
        return new OperationContext("tasignatura_plan", "TASIGNATURA_PLAN",
            "ACADEMICO", "PK_TASIGNATURA_PLAN", true, false, false);
    }
}
