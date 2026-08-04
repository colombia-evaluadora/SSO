package com.example.cdc.audit;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class SlotTest {

    @Test
    void code_is_snake_case_for_every_value() {
        assertThat(Slot.PK_T.code()).isEqualTo("pk_t");
        assertThat(Slot.CODIGO.code()).isEqualTo("codigo");
        assertThat(Slot.VALOR.code()).isEqualTo("valor");
        assertThat(Slot.NOMBRE.code()).isEqualTo("nombre");
        assertThat(Slot.FECHA.code()).isEqualTo("fecha");
        assertThat(Slot.FECHA_TS.code()).isEqualTo("fecha_ts");
        assertThat(Slot.NUMERO.code()).isEqualTo("numero");
        assertThat(Slot.DECIMAL.code()).isEqualTo("decimal");
        assertThat(Slot.TEXTO.code()).isEqualTo("texto");
        assertThat(Slot.BOOLEANO_SN.code()).isEqualTo("booleano_sn");
        assertThat(Slot.PADRE_ID_JSON.code()).isEqualTo("padre_id_json");
        assertThat(Slot.NONE.code()).isEqualTo("none");
    }

    @Test
    void values_are_in_declared_order() {
        Slot[] order = Slot.values();
        assertThat(order[0]).isEqualTo(Slot.PK_T);
        assertThat(order[order.length - 1]).isEqualTo(Slot.NONE);
        assertThat(order).hasSize(12);
    }
}
