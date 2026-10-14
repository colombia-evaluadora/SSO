package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.ParametroDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.TipoHerramienta;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.TipoParametro;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.ValorDeSesion;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

class CompletadorSesionTest {

    private static final ParametroDef NOMBRE = new ParametroDef("BODY.NOMBRE", TipoParametro.texto(), "Nombre",
            Optional.empty(), false, true);
    private static final ParametroDef DOCENTE = new ParametroDef("BODY.FK_TFUNCIONARIO", TipoParametro.texto(),
            "Docente", Optional.of("funcionarios_listar"), true, false, Optional.of(ValorDeSesion.FUNCIONARIO));
    private static final HerramientaDef CREAR = new HerramientaDef(1L, "crear_unidad_planeador",
            TipoHerramienta.ESCRITURA, "Crea una unidad", List.of(NOMBRE, DOCENTE), true, List.of(), 1,
            Optional.of("PLANEADOR"), Optional.empty(), Set.of());

    @Test
    void ponElFuncionarioDeLaSesionSiElModeloNoLoManda() {
        CompletadorSesion completador = new CompletadorSesion(userId -> userId == 7L ? Optional.of(990651L) : Optional.empty());

        ArgumentosCanonicos r = completador.completar(CREAR, new ArgumentosCanonicos(Map.of("BODY.NOMBRE", "Fracciones")), 7L);

        assertThat(r.planos()).containsEntry("BODY.FK_TFUNCIONARIO", 990651L).containsEntry("BODY.NOMBRE", "Fracciones");
    }

    @Test
    void loQueElModeloMandaSeRespetaYSinSesionNoSeInventaNada() {
        CompletadorSesion conSesion = new CompletadorSesion(userId -> Optional.of(990651L));
        ArgumentosCanonicos otroDocente = new ArgumentosCanonicos(Map.of("BODY.NOMBRE", "F", "BODY.FK_TFUNCIONARIO", 6L));
        assertThat(conSesion.completar(CREAR, otroDocente, 7L).planos()).containsEntry("BODY.FK_TFUNCIONARIO", 6L);

        CompletadorSesion sinFuncionario = new CompletadorSesion(userId -> Optional.empty());
        ArgumentosCanonicos soloNombre = new ArgumentosCanonicos(Map.of("BODY.NOMBRE", "F"));
        assertThat(sinFuncionario.completar(CREAR, soloNombre, 7L)).isSameAs(soloNombre);
    }
}
