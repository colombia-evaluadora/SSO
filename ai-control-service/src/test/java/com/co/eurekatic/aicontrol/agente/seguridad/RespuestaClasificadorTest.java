package com.co.eurekatic.aicontrol.agente.seguridad;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import tools.jackson.databind.json.JsonMapper;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class RespuestaClasificadorTest {

    private static final JsonMapper JSON = JsonMapper.builder().build();

    @Test
    void riesgoBajoNoEsHallazgo() {
        assertThat(RespuestaClasificador.leer("{\"riesgo\": \"BAJO\"}", JSON)).isEmpty();
    }

    @Test
    void riesgoMedioOAltoSeLeeComoHallazgoDelClasificador() {
        assertThat(RespuestaClasificador.leer("{\"riesgo\": \"MEDIO\"}", JSON)).hasValueSatisfying(h -> {
            assertThat(h.capa()).isEqualTo(CapaSeguridad.CLASIFICADOR);
            assertThat(h.riesgo()).isEqualTo(Riesgo.MEDIO);
            assertThat(h.motivo()).isEqualTo(RespuestaClasificador.SOSPECHA);
        });
        assertThat(RespuestaClasificador.leer("{\"riesgo\": \"ALTO\"}", JSON))
                .hasValueSatisfying(h -> assertThat(h.riesgo()).isEqualTo(Riesgo.ALTO));
    }

    @Test
    void elMotivoLibreDelModeloNoSaleDeLaLectura() {
        assertThat(RespuestaClasificador.leer("{\"riesgo\": \"ALTO\", \"motivo\": \"texto del modelo\"}", JSON))
                .hasValueSatisfying(h -> assertThat(h.motivo()).isEqualTo(RespuestaClasificador.SOSPECHA));
    }

    @Test
    void aceptaElJsonEnvueltoEnTextoOEnUnaCercaDeCodigo() {
        String envuelto = "Aqui va:\n```json\n{\"riesgo\": \"ALTO\"}\n```";

        assertThat(RespuestaClasificador.leer(envuelto, JSON)).hasValueSatisfying(h ->
                assertThat(h.riesgo()).isEqualTo(Riesgo.ALTO));
    }

    @ParameterizedTest
    @ValueSource(strings = {
            "sin objeto",
            "{\"motivo\": \"sin riesgo\"}",
            "{\"riesgo\": \"CRITICO\"}",
            "{\"riesgo\": \"medio\"}",
            "{\"riesgo\": "
    })
    void saliaIlegibleLanzaSinConvertirlaEnRiesgo(String salida) {
        assertThatThrownBy(() -> RespuestaClasificador.leer(salida, JSON))
                .isInstanceOf(RuntimeException.class);
    }
}
