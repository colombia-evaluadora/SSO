package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.ParametroDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.TipoHerramienta;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.TipoParametro;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

class RedaccionTest {

    private static ParametroDef p(String clave, String descripcion) {
        return new ParametroDef(clave, TipoParametro.texto(), descripcion, Optional.empty(), false, false);
    }

    @Test
    void elResumenNombraCadaCampoSinLasInstruccionesParaElModelo() {
        HerramientaDef crear = new HerramientaDef(1L, "crear_unidad_planeador", TipoHerramienta.ESCRITURA,
                "Crea una unidad del planeador. Pregunta lo que falte.", List.of(
                p("BODY.NOMBRE", "Nombre de la unidad"),
                p("BODY.FK_TFUNCIONARIO", "Docente responsable; omitelo si es la propia persona: el sistema la pone"),
                p("BODY.FK_TLV_CALCULO_DEFINITIVA", "Calculo de la definitiva (catalogo). Obligatorio salvo Formativo"),
                p("BODY.PONDERACION", "Ponderacion en la unidad (0-100). Obligatoria si la unidad pondera")),
                true, List.of(), 1, Optional.empty(), Optional.empty(), Set.of());

        String resumen = Redaccion.resumenPropuesta(crear, new ArgumentosCanonicos(Map.of(
                "BODY.NOMBRE", "Fracciones", "BODY.FK_TFUNCIONARIO", 990651,
                "BODY.FK_TLV_CALCULO_DEFINITIVA", 370, "BODY.PONDERACION", 100)));

        assertThat(resumen).isEqualTo("Crea una unidad del planeador (Nombre de la unidad: Fracciones; "
                + "Docente responsable: 990651; Calculo de la definitiva: 370; Ponderacion en la unidad: 100)");
    }
}
