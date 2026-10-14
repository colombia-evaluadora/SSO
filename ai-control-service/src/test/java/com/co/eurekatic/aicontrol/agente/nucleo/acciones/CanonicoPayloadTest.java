package com.co.eurekatic.aicontrol.agente.nucleo.acciones;

import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.ArgumentosCanonicos;
import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.List;
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
    void laHuellaTambienIgnoraElOrdenDeLosObjetosAnidados() {
        // La definicion de un instrumento: Postgres reordena las claves del JSONB en todos los niveles.
        Map<String, Object> definicion = new LinkedHashMap<>();
        definicion.put("valorMin", 0);
        definicion.put("valorMax", 100);
        definicion.put("criterios", List.of(Map.of("nombre", "General", "peso", 100)));
        ArgumentosCanonicos argumentos = new ArgumentosCanonicos(Map.of("PARAM.ID", 653, "BODY.DEFINICION", definicion));
        String guardado = CanonicoPayload.serializar(argumentos);

        String comoLoDevuelveLaBase = "{\"PARAM.ID\": 653, \"BODY.DEFINICION\": {\"valorMax\": 100, \"criterios\": "
                + "[{\"peso\": 100, \"nombre\": \"General\"}], \"valorMin\": 0}}";

        assertThat(CanonicoPayload.canonico(comoLoDevuelveLaBase)).isEqualTo(guardado);
        assertThat(guardado).contains("{\"criterios\":[{\"nombre\":\"General\",\"peso\":100}],\"valorMax\":100,\"valorMin\":0}");
    }

    @Test
    void elOrdenDeLasListasSiCuenta() {
        String unOrden = CanonicoPayload.serializar(new ArgumentosCanonicos(Map.of("BODY.FK_TMATRICULAS", List.of(1, 2))));
        String otro = CanonicoPayload.serializar(new ArgumentosCanonicos(Map.of("BODY.FK_TMATRICULAS", List.of(2, 1))));

        assertThat(unOrden).isNotEqualTo(otro);
    }

    @Test
    void leerRecuperaLosArgumentosConSusClaves() {
        ArgumentosCanonicos leidos = CanonicoPayload.leer("{\"BODY.NOMBRE\": \"Ana\", \"QUERY.GRUPO\": \"5A\"}");

        assertThat(leidos.planos()).containsEntry("BODY.NOMBRE", "Ana").containsEntry("QUERY.GRUPO", "5A");
    }
}
