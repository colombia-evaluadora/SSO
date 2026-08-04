package com.example.cdc.worker.pipeline;

import com.example.cdc.audit.ColumnTypeRegistry;
import com.example.cdc.audit.Slot;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class JsonTypedRowBuilderTest {

    private ColumnTypeRegistry registry;
    private JsonTypedRowBuilder builder;

    @BeforeEach
    void setUp() {
        registry = ColumnTypeRegistry.loadFromClasspath(
                "column-types-fixture.json");
        builder = new JsonTypedRowBuilder(registry);
    }

    @Test
    void pk_column_lands_in_pk_t() {
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("pk_lista_valor", 42L);
        row.put("categoria", "X");

        Map<String, Object> out = builder.build("tlista_valor", row);

        assertThat(out).containsEntry("pk_t", 42L);
        assertThat(out).containsEntry("pk_lista_valor", 42L); // preserved for PK extraction
        assertThat(out).containsEntry("codigo", "X");
    }

    @Test
    void multiple_fks_collected_into_padre_id_json_array() {
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("pk_tusuario", 7L);
        row.put("fk_tmunicipio", 5L);
        row.put("fk_testablecimiento", 10L);
        row.put("fk_tetnia", null);
        row.put("fk_tdiscapacidad", 3L);

        Map<String, Object> out = builder.build("tusuario", row);

        @SuppressWarnings("unchecked")
        List<Map<String, Object>> fks =
                (List<Map<String, Object>>) out.get("padre_id_json");
        assertThat(fks).hasSize(4);
        assertThat(fks.get(0))
                .containsEntry("name", "fk_tmunicipio")
                .containsEntry("value", "5");
        assertThat(fks.get(1))
                .containsEntry("name", "fk_testablecimiento")
                .containsEntry("value", "10");
        assertThat(fks.get(2))
                .containsEntry("name", "fk_tetnia")
                .containsEntry("value", null);
        assertThat(fks.get(3))
                .containsEntry("name", "fk_tdiscapacidad")
                .containsEntry("value", "3");
        // original FK names not in the dynamic part
        assertThat(out).doesNotContainKey("fk_tmunicipio");
        assertThat(out).doesNotContainKey("fk_testablecimiento");
    }

    @Test
    void first_timestamp_wins_fecha_ts_others_go_to_dynamic() {
        // tlista_valor has created_at then modified_at → both match fecha_ts.
        // The first (created_at) wins the slot; modified_at goes to dynamic.
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("created_at", "2026-07-31T19:25:34.123Z");
        row.put("modified_at", "2026-08-01T08:00:00Z");

        Map<String, Object> out = builder.build("tlista_valor", row);

        // Coerced output uses ISO_LOCAL_DATE_TIME (no Z) because
        // ClickHouse JSON DateTime64 rejects trailing 'Z'.
        assertThat(out).containsEntry("fecha_ts", "2026-07-31T19:25:34.123");
        assertThat(out).containsEntry("modified_at", "2026-08-01T08:00:00Z");
    }

    @Test
    void unknown_table_falls_back_to_dynamic() {
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("any_col", "any_value");
        row.put("pk_xyz", 1L);

        Map<String, Object> out = builder.build("tabla_inexistente", row);

        // Everything goes to dynamic
        assertThat(out).containsEntry("any_col", "any_value");
        assertThat(out).containsEntry("pk_xyz", 1L);
        // No canonical slot
        assertThat(out).doesNotContainKey("pk_t");
        assertThat(out).doesNotContainKey("padre_id_json");
    }

    @Test
    void null_value_in_typed_slot_is_preserved_as_null() {
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("pk_lista_valor", null);
        row.put("categoria", null);

        Map<String, Object> out = builder.build("tlista_valor", row);

        assertThat(out).containsEntry("pk_t", null);
        assertThat(out).containsEntry("codigo", null);
    }

    @Test
    void empty_input_row_produces_empty_output() {
        Map<String, Object> out = builder.build("tlista_valor",
                new LinkedHashMap<>());
        assertThat(out).isEmpty();
    }

    @Test
    void does_not_mutate_input_row() {
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("pk_lista_valor", 42L);
        row.put("categoria", "X");

        Map<String, Object> before = new LinkedHashMap<>(row);
        builder.build("tlista_valor", row);

        assertThat(row).isEqualTo(before);
    }

    // --- spec §8 type-coercion tests (added to fix the §8 gap) ---

    @Test
    void fecha_ts_epoch_millis_long_coerced_to_iso8601_string() {
        // Smoke test showed 2299-12-31 23:46:52 because ClickHouse parses
        // epoch-millis Longs as epoch SECONDS. Coerce to ISO_LOCAL_DATE_TIME
        // (no Z, since ClickHouse JSON DateTime64 rejects trailing 'Z').
        Map<String, Object> row = new LinkedHashMap<>();
        // 1785525747789 millis = 2026-07-31T19:22:27.789 UTC
        row.put("created_at", 1785525747789L);

        Map<String, Object> out = builder.build("tlista_valor", row);

        assertThat(out).containsEntry("fecha_ts", "2026-07-31T19:22:27.789");
    }

    @Test
    void pk_t_numeric_string_coerced_to_long() {
        // Debezium may emit BIGINT as String under some serializers.
        // Coerce to Long so ClickHouse can read the pk_t slot as Int64.
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("pk_lista_valor", "42");
        row.put("categoria", "X");

        Map<String, Object> out = builder.build("tlista_valor", row);

        assertThat(out).containsEntry("pk_t", 42L);
    }

    @Test
    void decimal_numeric_string_coerced_to_bigdecimal() {
        // tusuario.saldo → decimal slot. Input arrives as String.
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("pk_tusuario", 1L);
        row.put("saldo", "1234.56");

        Map<String, Object> out = builder.build("tusuario", row);

        assertThat(out.get("decimal"))
                .isEqualTo(new java.math.BigDecimal("1234.56"));
    }

    @Test
    void boolean_coerced_to_SN_string() {
        // tusuario.estado → booleano_sn slot. Input arrives as Boolean.
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("pk_tusuario", 1L);
        row.put("estado", Boolean.TRUE);

        Map<String, Object> out = builder.build("tusuario", row);

        assertThat(out).containsEntry("booleano_sn", "S");
    }

    @Test
    void fecha_epoch_days_long_coerced_to_iso_date_string() {
        // Debezium sends Postgres DATE as epoch-days (Long under
        // time.precision.mode=connect). ClickHouse JSON Date rejects
        // a raw integer — coerce to "yyyy-MM-dd" via LocalDate.ofEpochDay.
        // 20669 days from 1970-01-01 = 2026-08-04.
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("pk_tsesion", 99999999L);
        row.put("fecha_ingreso", 20669L);

        Map<String, Object> out = builder.build("tsesion", row);

        assertThat(out).containsEntry("fecha", "2026-08-04");
    }
}
