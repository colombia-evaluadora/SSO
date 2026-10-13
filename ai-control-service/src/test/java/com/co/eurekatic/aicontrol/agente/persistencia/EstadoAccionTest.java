package com.co.eurekatic.aicontrol.agente.persistencia;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class EstadoAccionTest {

    @Test
    void solamentePendienteAvanzaAUnEstadoFinal() {
        assertThat(EstadoAccion.PENDIENTE.puedePasarA(EstadoAccion.EJECUTADA)).isTrue();
        assertThat(EstadoAccion.PENDIENTE.puedePasarA(EstadoAccion.FALLIDA)).isTrue();
        assertThat(EstadoAccion.PENDIENTE.puedePasarA(EstadoAccion.DESCARTADA)).isTrue();
        assertThat(EstadoAccion.PENDIENTE.puedePasarA(EstadoAccion.EXPIRADA)).isTrue();
        assertThat(EstadoAccion.PENDIENTE.puedePasarA(EstadoAccion.PENDIENTE)).isFalse();
    }

    @Test
    void losEstadosFinalesNoCambianANada() {
        for (EstadoAccion origen : EstadoAccion.values()) {
            if (origen == EstadoAccion.PENDIENTE) {
                continue;
            }
            for (EstadoAccion nuevo : EstadoAccion.values()) {
                assertThat(origen.puedePasarA(nuevo)).as(origen + " -> " + nuevo).isFalse();
            }
        }
    }
}
