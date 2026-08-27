package com.example.cdc.worker.pipeline;

import com.example.cdc.audit.ColumnTypeRegistry;
import com.example.cdc.common.event.CdcEvent;
import com.example.cdc.common.event.Operation;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class AuditRecordTest {

    private ColumnTypeRegistry registry;
    private JsonTypedRowBuilder builder;

    @BeforeEach
    void setUp() {
        registry = ColumnTypeRegistry.loadFromClasspath("column-types-fixture.json");
        builder = new JsonTypedRowBuilder(registry);
    }

    @Test
    void extracts_academic_pk_column_instead_of_id() {
        Map<String, Object> after = new LinkedHashMap<>();
        after.put("pk_lista_valor", 42L);
        after.put("categoria", "PK_TEST");
        after.put("id", 999L);
        CdcEvent event = event(Operation.INSERT, null, after);

        AuditRecord record = AuditRecord.fromEvent(event, 0, 123L, 7L,
                null, "OK", 1L, builder);

        assertThat(record.pk()).isEqualTo("42");
    }

    @Test
    void joins_multiple_pk_columns_in_event_order() {
        Map<String, Object> after = new LinkedHashMap<>();
        after.put("pk_second", 20L);
        after.put("name", "composite");
        after.put("pk_first", 10L);
        CdcEvent event = event(Operation.UPDATE, null, after);

        AuditRecord record = AuditRecord.fromEvent(event, 0, 123L, 7L,
                null, "OK", 1L, builder);

        assertThat(record.pk()).isEqualTo("20,10");
    }

    @Test
    void falls_back_to_row_hash_when_no_pk_column_exists() {
        Map<String, Object> before = Map.of("name", "no-primary-key");
        CdcEvent event = event(Operation.DELETE, before, null);

        AuditRecord record = AuditRecord.fromEvent(event, 0, 123L, 7L,
                null, "OK", 1L, builder);

        assertThat(record.pk()).isEqualTo(String.valueOf(before.hashCode()));
    }

    @Test
    void fila_new_is_typed_projection_not_raw_event_after() {
        Map<String, Object> after = new LinkedHashMap<>();
        after.put("pk_lista_valor", 42L);
        after.put("categoria", "TYPED");
        CdcEvent event = event(Operation.INSERT, null, after);

        AuditRecord record = AuditRecord.fromEvent(event, 0, 123L, 7L,
                null, "OK", 1L, builder);

        // pk_lista_valor moved to pk_t; categoria moved to codigo
        assertThat(record.filaNew())
                .containsEntry("pk_t", 42L)
                .containsEntry("codigo", "TYPED")
                .containsEntry("pk_lista_valor", 42L)
                .doesNotContainKey("categoria");
    }

    @Test
    void fila_new_raw_preserves_real_column_names_the_typed_projection_loses() {
        // Mismo evento del test de arriba: el proyector tipado renombra
        // "categoria" a "codigo" y esa identidad real desaparece — el raw
        // es justo lo que hace falta para reconstruir un revert sin
        // adivinar de qué columna venía el slot.
        Map<String, Object> after = new LinkedHashMap<>();
        after.put("pk_lista_valor", 42L);
        after.put("categoria", "TYPED");
        CdcEvent event = event(Operation.INSERT, null, after);

        AuditRecord record = AuditRecord.fromEvent(event, 0, 123L, 7L,
                null, "OK", 1L, builder);

        assertThat(record.filaNewRawJson())
                .contains("\"pk_lista_valor\":42")
                .contains("\"categoria\":\"TYPED\"");
    }

    @Test
    void fila_old_raw_is_empty_string_for_null_before() {
        Map<String, Object> after = new LinkedHashMap<>();
        after.put("pk_lista_valor", 42L);
        CdcEvent event = event(Operation.INSERT, null, after);

        AuditRecord record = AuditRecord.fromEvent(event, 0, 123L, 7L,
                null, "OK", 1L, builder);

        assertThat(record.filaOldRawJson()).isEmpty();
    }

    private static CdcEvent event(Operation operation,
                                  Map<String, Object> before,
                                  Map<String, Object> after) {
        return new CdcEvent(
                operation,
                before,
                after,
                new CdcEvent.Source("academico", "academico_test", "tlista_valor",
                        7L, 123L, "false"),
                1712345678000L,
                "academico_test.tlista_valor",
                null,
                null
        );
    }
}
