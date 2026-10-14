package com.co.eurekatic.aicontrol.agente.catalogo.carga;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class DetalleParaModeloTest {

    @Test
    void quitaFuncionesMigracionesReglasGateYErroresYConservaElContrato() {
        String detail = "V245 -- vincula una actividad a una unidad y fija su PONDERACION (%) dentro de ella "
                + "(fn_unidad_actividad_vincular, V223, editada en V244). BODY.PONDERACION NULL = no cambiar el peso; "
                + "se rechaza (22023) si la unidad Promedia (Regla 25c).CONTENIDOS_TITULOS (§4: si llega, uno por contenido). "
                + "Gate EDITAR sobre PLANEADOR. Errores: 404 (P0002) si no existe; 400 (22023) si ya fue eliminada.";

        String limpio = DetalleParaModelo.limpiar(detail).orElseThrow();

        assertThat(limpio).startsWith("vincula una actividad a una unidad y fija su PONDERACION (%) dentro de ella.")
                .contains("BODY.PONDERACION NULL = no cambiar el peso").contains("si llega, uno por contenido")
                .contains("se rechaza si la unidad Promedia").doesNotContain("22023")
                .doesNotContain("fn_").doesNotContain("V2").doesNotContain("Regla").doesNotContain("§")
                .doesNotContain("Gate").doesNotContain("Errores").doesNotContain("P0002");
    }

    @Test
    void conservaLosObligatoriosYSusCondicionesYRecortaPorFrase() {
        String detail = "Crea una unidad temática del Planeador (fn_unidad_crear). Obligatorios: NOMBRE, FK_TGRADO y "
                + "FK_TLV_CALCULO_DEFINITIVA salvo que el referente del grado sea de enfoque Formativo (Regla 19). "
                + "Opcionales: DESCRIPCION (máx. 150).";
        assertThat(DetalleParaModelo.limpiar(detail).orElseThrow())
                .isEqualTo("Crea una unidad temática del Planeador. Obligatorios: NOMBRE, FK_TGRADO y "
                        + "FK_TLV_CALCULO_DEFINITIVA salvo que el referente del grado sea de enfoque Formativo. "
                        + "Opcionales: DESCRIPCION (máx. 150).");

        String largo = "Frase uno con datos. ".repeat(80);
        assertThat(DetalleParaModelo.limpiar(largo).orElseThrow()).hasSizeLessThanOrEqualTo(DetalleParaModelo.MAX_CARACTERES)
                .endsWith(".");
        assertThat(DetalleParaModelo.limpiar("  ")).isEmpty();
        assertThat(DetalleParaModelo.limpiar(null)).isEmpty();
    }
}
