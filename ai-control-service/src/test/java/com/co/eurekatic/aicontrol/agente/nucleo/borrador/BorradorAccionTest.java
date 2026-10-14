package com.co.eurekatic.aicontrol.agente.nucleo.borrador;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.ParametroDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.TipoHerramienta;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.TipoParametro;
import com.co.eurekatic.aicontrol.agente.nucleo.TurnoContexto;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.json.JsonMapper;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

class BorradorAccionTest {

    private static final HerramientaDef CREAR = new HerramientaDef(9L, "crear_actividad_planeador",
            TipoHerramienta.ESCRITURA, "Crea una actividad",
            List.of(new ParametroDef("BODY.FK_TGRUPO", TipoParametro.texto(), "Grupo; sale de docentes_grupos_listar",
                            Optional.of("docentes_grupos_listar"), true, false),
                    new ParametroDef("BODY.TITULO", TipoParametro.texto(), "Titulo", Optional.empty(), true, false),
                    new ParametroDef("BODY.PONDERACION", TipoParametro.texto(), "Peso", Optional.empty(), false, false)),
            true, List.of(), 1, Optional.empty(), Optional.empty(), Set.of());

    @Test
    void guardaSoloLosParametrosDeLaHerramientaConValor() {
        Map<String, Object> argumentos = new HashMap<>();
        argumentos.put("BODY.FK_TGRUPO", 990201);
        argumentos.put("BODY.TITULO", " ");
        argumentos.put("BODY.PONDERACION", null);
        argumentos.put("inventado", "x");

        assertThat(BorradorAccion.de(CREAR, argumentos).argumentos()).containsExactly(Map.entry("BODY.FK_TGRUPO", 990201));
    }

    @Test
    void elIntentoNuevoCompletaElDeLaMismaHerramientaYReemplazaElDeOtra() {
        BorradorAccion antes = new BorradorAccion("crear_actividad_planeador", Map.of("BODY.FK_TGRUPO", 990201,
                "BODY.TITULO", "Taller"));

        assertThat(antes.seguidoDe(new BorradorAccion("crear_actividad_planeador", Map.of("BODY.TITULO", "Quiz")))
                .argumentos()).containsEntry("BODY.FK_TGRUPO", 990201).containsEntry("BODY.TITULO", "Quiz");
        assertThat(antes.seguidoDe(new BorradorAccion("editar_funcionario", Map.of("PARAM.ID", 7))).argumentos())
                .containsOnlyKeys("PARAM.ID");
    }

    @Test
    void laNotaNombraCadaCampoConSuEtiquetaYSuClave() {
        String nota = new BorradorAccion("crear_actividad_planeador", Map.of("BODY.FK_TGRUPO", 990201)).nota(CREAR);

        assertThat(nota).contains("Accion en curso", "crear_actividad_planeador", "Grupo [BODY.FK_TGRUPO] = 990201")
                .doesNotContain("docentes_grupos_listar");
        assertThat(new BorradorAccion("crear_actividad_planeador", Map.of()).nota(CREAR)).isEmpty();
    }

    @Test
    void elTurnoJuntaLosIntentosDeEscrituraQueHaceElModelo() {
        TurnoContexto turno = new TurnoContexto(List.of(CREAR));

        assertThat(turno.borrador()).isEmpty();
        turno.alIntentarEscritura(CREAR, Map.of("BODY.FK_TGRUPO", 990201));
        turno.alIntentarEscritura(CREAR, Map.of("BODY.TITULO", "Taller"));

        assertThat(turno.borrador()).hasValueSatisfying(b -> assertThat(b.argumentos())
                .containsOnlyKeys("BODY.FK_TGRUPO", "BODY.TITULO"));
    }

    @Test
    void viajaComoJsonYVuelveIgual() {
        JsonMapper json = JsonMapper.builder().build();
        BorradorAccion borrador = new BorradorAccion("crear_actividad_planeador",
                Map.of("BODY.FK_TGRUPO", 990201, "BODY.TITULO", "Taller"));

        assertThat(json.readValue(json.writeValueAsString(borrador), BorradorAccion.class)).isEqualTo(borrador);
    }
}
