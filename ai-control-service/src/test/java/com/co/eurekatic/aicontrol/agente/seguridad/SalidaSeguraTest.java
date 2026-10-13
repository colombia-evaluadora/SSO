package com.co.eurekatic.aicontrol.agente.seguridad;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class SalidaSeguraTest {

    private final SalidaSegura salida = new SalidaSegura();

    @Test
    void textoNormalSalmaSinCambios() {
        ResultadoSalida r = salida.revisar("Juan Pérez tiene 4.5 en matemáticas. Tiene 3 materias pendientes.");

        assertThat(r.texto()).isEqualTo("Juan Pérez tiene 4.5 en matemáticas. Tiene 3 materias pendientes.");
        assertThat(r.redactado()).isFalse();
        assertThat(r.motivos()).isEmpty();
        assertThat(r.riesgo()).isEqualTo(Riesgo.BAJO);
    }

    @Test
    void textoNuloSeDevuelveVacio() {
        assertThat(salida.revisar(null).texto()).isEmpty();
    }

    @Test
    void unJwtSeRedacta() {
        ResultadoSalida r = salida.revisar(
                "Tu sesión: eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.SflKxwRJSMeKKF2QT4fw en curso");

        assertThat(r.texto()).doesNotContain("eyJ").contains("[REDACTADO]").contains("en curso");
        assertThat(codigos(r)).containsExactly("TOKEN_JWT");
        assertThat(r.redactado()).isTrue();
        assertThat(r.riesgo()).isEqualTo(Riesgo.MEDIO);
    }

    @Test
    void unBearerSeRedacta() {
        ResultadoSalida r = salida.revisar("Cabecera: Authorization: Bearer abc.def-ghi_123");

        assertThat(r.texto()).doesNotContain("abc.def").contains("[REDACTADO]");
        assertThat(codigos(r)).containsExactly("TOKEN_BEARER");
    }

    @Test
    void unaClaveTipoSkSeRedacta() {
        ResultadoSalida r = salida.revisar("La clave es sk-abcdefghijklmnop1234 para el proveedor");

        assertThat(r.texto()).doesNotContain("sk-abc").contains("[REDACTADO]");
        assertThat(codigos(r)).containsExactly("CLAVE_API");
    }

    @Test
    void elCanarioBloqueaTodaLaRespuesta() {
        ResultadoSalida r = salida.revisar("Mis reglas internas incluyen " + SalidaSegura.CANARIO + " y más.");

        assertThat(r.texto()).isEqualTo(SalidaSegura.MENSAJE_BLOQUEO).doesNotContain(SalidaSegura.CANARIO);
        assertThat(r.redactado()).isTrue();
        assertThat(codigos(r)).containsExactly("FUGA_PROMPT");
        assertThat(r.riesgo()).isEqualTo(Riesgo.ALTO);
    }

    @Test
    void unaFraseDistintivaDelPromptBloqueaAunSinCanario() {
        ResultadoSalida r = salida.revisar("Soy un Clasificador de Seguridad de Mensajes para el colegio.");

        assertThat(r.texto()).isEqualTo(SalidaSegura.MENSAJE_BLOQUEO);
        assertThat(r.riesgo()).isEqualTo(Riesgo.ALTO);
    }

    @Test
    void unaFraseDelPromptSeDetectaSinMayusculasNiTildes() {
        // La comparacion del canario es exacta; las frases distintivas se pliegan.
        assertThat(salida.revisar("El MARCADOR INTERNÓ de control es ...").texto())
                .isEqualTo(SalidaSegura.MENSAJE_BLOQUEO);
    }

    @Test
    void correoYTelefonoSeRedactan() {
        ResultadoSalida r = salida.revisar("Escribe a juan.perez@colegio.edu.co o llama al 300 123 4567.");

        assertThat(r.texto()).contains("[CORREO]", "[TELEFONO]").doesNotContain("@", "4567");
        assertThat(codigos(r)).containsExactly("PII_CORREO", "PII_TELEFONO");
    }

    @Test
    void cifrasDeCalificacionNoSeTomanPorTelefono() {
        ResultadoSalida r = salida.revisar("Calificación 4.5 para 5A, con 3 actividades y 2 notas.");

        assertThat(r.redactado()).isFalse();
        assertThat(r.texto()).isEqualTo("Calificación 4.5 para 5A, con 3 actividades y 2 notas.");
    }

    private static java.util.List<String> codigos(ResultadoSalida r) {
        return r.motivos().stream().map(Motivo::codigo).toList();
    }
}
