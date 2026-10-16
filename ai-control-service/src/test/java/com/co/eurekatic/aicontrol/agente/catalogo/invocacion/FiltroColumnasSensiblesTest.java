package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class FiltroColumnasSensiblesTest {

    private final FiltroColumnasSensibles filtro = new FiltroColumnasSensibles(List.of(
            "identificacion", "documento", "correo", "email", "telefono", "celular", "direccion",
            "fecha_nacimiento", "password", "contrasena", "token"));

    @Test
    void quitaLasColumnasSensiblesYConservaIdsYNombres() {
        Map<String, Object> fila = Map.of(
                "id", 7,
                "nombre", "Ana",
                "numero_documento", "1020304050",
                "correo_institucional", "ana@x.co",
                "fk_tdocumento", 3,
                "telefono", "3001234567");

        List<Map<String, Object>> r = filtro.aplicar(List.of(fila));

        assertThat(r).hasSize(1);
        assertThat(r.get(0)).containsOnlyKeys("id", "nombre", "fk_tdocumento");
    }

    @Test
    void laCoincidenciaNoDistingueMayusculas() {
        assertThat(filtro.esSensible("NUMERO_DOCUMENTO")).isTrue();
        assertThat(filtro.esSensible("Email")).isTrue();
        assertThat(filtro.esSensible("nombre")).isFalse();
    }

    @Test
    void unIdConFragmentoSensibleSeConserva() {
        assertThat(filtro.esSensible("fk_tdocumento")).isFalse();
        assertThat(filtro.esSensible("documento_id")).isFalse();
    }

    @Test
    void revisaTambienLosValoresAnidados() {
        Map<String, Object> fila = Map.of("persona", Map.of("nombre", "Ana", "email", "a@b.co"));

        List<Map<String, Object>> r = filtro.aplicar(List.of(fila));

        assertThat(r.get(0)).containsKey("persona");
        assertThat(r.get(0).get("persona"))
                .asInstanceOf(org.assertj.core.api.InstanceOfAssertFactories.MAP)
                .containsOnlyKeys("nombre");
    }

    @Test
    void unaListaVaciaDeSensiblesNoQuitaNada() {
        FiltroColumnasSensibles sin = new FiltroColumnasSensibles(List.of());

        assertThat(sin.aplicar(List.of(Map.of("email", "a@b.co")))).isEqualTo(List.of(Map.of("email", "a@b.co")));
    }
}
