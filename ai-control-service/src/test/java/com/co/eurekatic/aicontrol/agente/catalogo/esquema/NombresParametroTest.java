package com.co.eurekatic.aicontrol.agente.catalogo.esquema;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.ParametroDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.TipoParametro;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class NombresParametroTest {

    @Test
    void nombreCortoEnMinusculasYIdaYVueltaAlaClaveCanonica() {
        NombresParametro nombres = NombresParametro.de(List.of(
                parametro("PARAM.ID"), parametro("BODY.PERSON.EMAIL"), parametro("BODY.FK_TSEDE")));

        assertThat(nombres.nombreModelo("PARAM.ID")).isEqualTo("id");
        assertThat(nombres.nombreModelo("BODY.PERSON.EMAIL")).isEqualTo("person_email");
        assertThat(nombres.nombreModelo("BODY.FK_TSEDE")).isEqualTo("fk_tsede");
        assertThat(nombres.claveCanonica("person_email")).contains("BODY.PERSON.EMAIL");
        assertThat(nombres.claveCanonica("inventado")).isEqualTo(Optional.empty());
    }

    @Test
    void siDosClavesDanElMismoNombreCortoUsanElNombreCompleto() {
        NombresParametro nombres = NombresParametro.de(List.of(
                parametro("PARAM.ID"), parametro("BODY.ID")));

        assertThat(nombres.nombreModelo("PARAM.ID")).isEqualTo("param_id");
        assertThat(nombres.nombreModelo("BODY.ID")).isEqualTo("body_id");
    }

    @Test
    void nombreDesconocidoEnLaClaveLanza() {
        NombresParametro nombres = NombresParametro.de(List.of(parametro("PARAM.ID")));

        assertThatThrownBy(() -> nombres.nombreModelo("QUERY.X"))
                .isInstanceOf(IllegalArgumentException.class);
    }

    private static ParametroDef parametro(String clave) {
        return new ParametroDef(clave, TipoParametro.texto(), "d", Optional.empty(), false, false);
    }
}
