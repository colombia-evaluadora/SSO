package com.example.cdc.audit;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class ColumnTypeRegistryTest {

    // The fixture uses simpler slot rules than the real generator (e.g.
    // categoria -> codigo here, but categoria -> texto in the real
    // generated column-types.json). This is intentional — these tests
    // assert builder behavior against a stable hand-curated shape, not
    // slot-rule fidelity. The real registry is exercised separately by
    // loads_bundled_column_types_with_all_147_tables and
    // bundled_registry_resolves_known_columns.

    private final ColumnTypeRegistry registry =
            ColumnTypeRegistry.loadFromClasspath("column-types-fixture.json");

    @Test
    void resolves_pk_column_to_pk_t() {
        assertThat(registry.slotFor("tlista_valor", "pk_lista_valor"))
                .isEqualTo(Slot.PK_T);
    }

    @Test
    void resolves_fk_column_to_padre_id_json() {
        assertThat(registry.slotFor("tusuario", "fk_tmunicipio"))
                .isEqualTo(Slot.PADRE_ID_JSON);
    }

    @Test
    void resolves_timestamp_column_to_fecha_ts() {
        assertThat(registry.slotFor("tlista_valor", "created_at"))
                .isEqualTo(Slot.FECHA_TS);
    }

    @Test
    void resolves_decimal_column() {
        assertThat(registry.slotFor("tusuario", "saldo"))
                .isEqualTo(Slot.DECIMAL);
    }

    @Test
    void returns_none_for_unknown_table() {
        assertThat(registry.slotFor("no_existe", "cualquiera"))
                .isEqualTo(Slot.NONE);
    }

    @Test
    void returns_none_for_unknown_column_in_known_table() {
        assertThat(registry.slotFor("tlista_valor", "columna_inexistente"))
                .isEqualTo(Slot.NONE);
    }

    @Test
    void exposes_known_table_set() {
        assertThat(registry.tables())
                .containsExactlyInAnyOrder("tlista_valor", "tusuario", "tactividad");
    }

    @Test
    void loads_bundled_column_types_with_all_147_tables() {
        ColumnTypeRegistry real = ColumnTypeRegistry.loadFromClasspath("column-types.json");
        // 147 tables in the academico_test schema, per spec §10
        assertThat(real.tables()).hasSize(147);
    }

    @Test
    void bundled_registry_resolves_known_columns() {
        ColumnTypeRegistry real = ColumnTypeRegistry.loadFromClasspath("column-types.json");
        // spot-checks
        assertThat(real.slotFor("tlista_valor", "pk_lista_valor"))
                .isEqualTo(Slot.PK_T);
        // updated to fk_tmunicipio_documento due to tusuario schema drift on 2026-07-31
        // (brief used fk_tmunicipio from the hand-written fixture; bundled schema splits
        //  this into _documento / _residencia / _nacimiento)
        assertThat(real.slotFor("tusuario", "fk_tmunicipio_documento"))
                .isEqualTo(Slot.PADRE_ID_JSON);
        assertThat(real.slotFor("tactividad", "created_at"))
                .isEqualTo(Slot.FECHA_TS);
    }
}
