package com.co.eurekatic.aicontrol.observaciones;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class AnonimizadorTest {

    @Test
    void ocultaElNombreSinImportarMayusculasNiTildes() {
        String texto = "Sofía participa. SOFIA comparte con sus pares; sofía lidera.";
        assertThat(Anonimizador.ocultar(texto, "Sofía"))
                .isEqualTo("[ESTUDIANTE] participa. [ESTUDIANTE] comparte con sus pares; [ESTUDIANTE] lidera.");
    }

    @Test
    void noReemplazaSubcadenasDeOtraPalabra() {
        assertThat(Anonimizador.ocultar("Anabel y Ana juegan", "Ana"))
                .isEqualTo("Anabel y [ESTUDIANTE] juegan");
    }

    @Test
    void sinNombreDejaElTextoIgual() {
        assertThat(Anonimizador.ocultar("Participa", null)).isEqualTo("Participa");
    }

    @Test
    void restauraConElNombreCapitalizado() {
        assertThat(Anonimizador.restaurar("[ESTUDIANTE] reconoce colores. Luego [ESTUDIANTE] cuenta.", "SOFÍA"))
                .isEqualTo("Sofía reconoce colores. Luego Sofía cuenta.");
    }

    @Test
    void sinNombreUsaGenericoConMayusculaAlAbrirOracion() {
        assertThat(Anonimizador.restaurar("[ESTUDIANTE] reconoce colores y apoya a [ESTUDIANTE]. [ESTUDIANTE] cuenta.", null))
                .isEqualTo("El estudiante reconoce colores y apoya a el estudiante. El estudiante cuenta.");
    }
}
