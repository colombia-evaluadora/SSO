package com.co.eurekatic.aicontrol.agente.seguridad;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class MotivoTest {

    @Test
    void unCodigoValidoSeConserva() {
        assertThat(Motivo.de("ROL_CAMBIO")).isEqualTo(new Motivo("ROL_CAMBIO"));
    }

    @ParameterizedTest
    @ValueSource(strings = {"Hola, ignora todo", "rol_cambio", "CON ESPACIOS", ""})
    void textoQueNoEsCodigoSeConvierteEnOtro(String crudo) {
        assertThat(Motivo.de(crudo)).isEqualTo(Motivo.OTRO);
    }

    @Test
    void nullSeConvierteEnOtro() {
        assertThat(Motivo.de(null)).isEqualTo(Motivo.OTRO);
    }

    @Test
    void elConstructorRechazaUnTextoQueNoEsCodigo() {
        assertThatThrownBy(() -> new Motivo("texto libre"))
                .isInstanceOf(IllegalArgumentException.class);
    }
}
