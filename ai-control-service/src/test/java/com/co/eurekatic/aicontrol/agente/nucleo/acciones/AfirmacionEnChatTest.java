package com.co.eurekatic.aicontrol.agente.nucleo.acciones;

import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.Redaccion;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class AfirmacionEnChatTest {

    @Test
    void reconoceLasConfirmacionesEscritasHabituales() {
        for (String texto : new String[] {"sí", "Sí, confirmo", "SI!!", "dale", "Hazlo.", "ok", "de acuerdo", "sí, por favor"}) {
            assertThat(AfirmacionEnChat.es(texto)).as(texto).isTrue();
        }
    }

    @Test
    void noConfundeOtrosMensajesConUnaConfirmacion() {
        for (String texto : new String[] {"sí, pero cambia la fecha al lunes", "no", "¿qué vas a hacer?",
                "si la actividad tiene notas no la cambies", ""}) {
            assertThat(AfirmacionEnChat.es(texto)).as(texto).isFalse();
        }
    }

    @Test
    void elResumenDeConfirmacionUsaLaPrimeraFraseDeLaDescripcion() {
        assertThat(Redaccion.accion("Edita una actividad existente del planeador: titulo, fechas. Requiere confirmacion."))
                .isEqualTo("Edita una actividad existente del planeador");
        assertThat(Redaccion.accion("Crea una unidad. Requiere confirmacion.")).isEqualTo("Crea una unidad");
    }
}
