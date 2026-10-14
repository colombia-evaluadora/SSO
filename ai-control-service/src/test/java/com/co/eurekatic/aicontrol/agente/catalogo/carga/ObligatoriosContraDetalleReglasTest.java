package com.co.eurekatic.aicontrol.agente.catalogo.carga;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.ParametroDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.TipoHerramienta;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.TipoParametro;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.ValorDeSesion;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Optional;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

/** Las reglas de {@link ObligatoriosContraDetalleTest} sin base: corren siempre, tambien en CI. */
class ObligatoriosContraDetalleReglasTest {

    private static final String DETAIL = "Crea una unidad (fn_unidad_crear). Obligatorios: NOMBRE, FK_TGRADO y "
            + "FK_TLV_CALCULO_DEFINITIVA salvo que el referente sea Formativo (Regla 19). FK_TFUNCIONARIO se deriva "
            + "del usuario si no llega. Opcionales: DESCRIPCION.";

    private static ParametroDef p(String clave, boolean obligatorio) {
        return new ParametroDef(clave, TipoParametro.texto(), "d", Optional.empty(), false, obligatorio);
    }

    private static HerramientaDef crear(ParametroDef... parametros) {
        return new HerramientaDef(1L, "crear_unidad_planeador", TipoHerramienta.ESCRITURA, "Crea", List.of(parametros),
                true, List.of(), 1, Optional.empty(), Optional.empty(), Set.of());
    }

    @Test
    void unCatalogoAlineadoNoDiverge() {
        HerramientaDef alineada = crear(p("BODY.NOMBRE", true), p("BODY.FK_TGRADO", true),
                p("BODY.FK_TLV_CALCULO_DEFINITIVA", false),
                new ParametroDef("BODY.FK_TFUNCIONARIO", TipoParametro.texto(), "d", Optional.empty(), true, false,
                        Optional.of(ValorDeSesion.FUNCIONARIO)));

        assertThat(ObligatoriosContraDetalleTest.divergencias(alineada, DETAIL)).isEmpty();
    }

    @Test
    void detectaElCondicionalFijoElDerivadoExigidoYElObligatorioOlvidado() {
        HerramientaDef desalineada = crear(p("BODY.NOMBRE", true), p("BODY.FK_TGRADO", false),
                p("BODY.FK_TLV_CALCULO_DEFINITIVA", true), p("BODY.FK_TFUNCIONARIO", true));

        assertThat(ObligatoriosContraDetalleTest.divergencias(desalineada, DETAIL)).containsExactlyInAnyOrder(
                "crear_unidad_planeador: BODY.FK_TGRADO es obligatorio en el detail y no en el catalogo",
                "crear_unidad_planeador: BODY.FK_TLV_CALCULO_DEFINITIVA es condicional en el detail y obligatorio fijo en el catalogo",
                "crear_unidad_planeador: BODY.FK_TFUNCIONARIO se deriva del usuario y el catalogo lo exige al modelo");
    }
}
