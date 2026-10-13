package com.co.eurekatic.aicontrol.agente.nucleo.acciones;

import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.ArgumentosCanonicos;
import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class CanonicoPayloadTest {

    @Test
    void laFormaCanonicaNoDependeDelOrdenNiDelEspaciadoQueDevuelveLaBase() {
        ArgumentosCanonicos argumentos = new ArgumentosCanonicos(Map.of("BODY.SEDE", 3, "BODY.NOMBRE", "Ana"));
        String guardado = CanonicoPayload.serializar(argumentos);

        // Postgres devuelve el JSONB con otro orden y con espacios: la huella debe seguir igual.
        String comoLoDevuelveLaBase = "{\"BODY.SEDE\": 3, \"BODY.NOMBRE\": \"Ana\"}";

        assertThat(guardado).isEqualTo("{\"BODY.NOMBRE\":\"Ana\",\"BODY.SEDE\":3}");
        assertThat(CanonicoPayload.canonico(comoLoDevuelveLaBase)).isEqualTo(guardado);
    }

    @Test
    void leerRecuperaLosArgumentosConSusClaves() {
        ArgumentosCanonicos leidos = CanonicoPayload.leer("{\"BODY.NOMBRE\": \"Ana\", \"QUERY.GRUPO\": \"5A\"}");

        assertThat(leidos.planos()).containsEntry("BODY.NOMBRE", "Ana").containsEntry("QUERY.GRUPO", "5A");
    }
}
