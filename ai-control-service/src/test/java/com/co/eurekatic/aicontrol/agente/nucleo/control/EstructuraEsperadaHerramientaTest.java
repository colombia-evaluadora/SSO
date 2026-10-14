package com.co.eurekatic.aicontrol.agente.nucleo.control;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.ParametroDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.RutaQuery;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.TipoHerramienta;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.TipoParametro;
import com.co.eurekatic.aicontrol.agente.catalogo.estructura.EstructuraEndpoint;
import com.co.eurekatic.aicontrol.agente.nucleo.TurnoContexto;
import org.junit.jupiter.api.Test;
import org.springframework.ai.chat.model.ToolContext;
import org.springframework.http.HttpMethod;

import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

class EstructuraEsperadaHerramientaTest {

    private static final HerramientaDef DEFINIR = new HerramientaDef(5L, "actualizar_instrumento_actividad",
            TipoHerramienta.ESCRITURA, "Reemplaza la definicion del instrumento",
            List.of(new ParametroDef("PARAM.ID", TipoParametro.de("BIGINT"), "Actividad", Optional.empty(), false, true),
                    new ParametroDef("BODY.DEFINICION", TipoParametro.de("JSONB"), "Definicion", Optional.empty(), false, false)),
            true, List.of(), 1, Optional.empty(),
            Optional.of(new RutaQuery(HttpMethod.PUT, "/planeador/actividades/:ID/instrumento",
                    Map.of("PARAM.ID", "BIGINT", "BODY.DEFINICION", "JSONB"), Map.of())),
            Set.of(), Optional.empty(), Optional.of("Define el instrumento de la actividad."));

    @Test
    void juntaEsquemaContratoYLoQueLaBaseLeeYValidaDeCualquierHerramienta() {
        EstructuraEndpoint estructura = id -> id == 5L ? List.of(new EstructuraEndpoint.Bloque("actividad_escala_definir",
                List.of("tipoEscala", "valorMax", "valorMin"), List.of("La escala numérica de … necesita valor mínimo y valor máximo")))
                : List.of();
        String salida = new EstructuraEsperadaHerramienta(estructura).callbacks().get(0)
                .call("{\"codigo\":\"actualizar_instrumento_actividad\"}",
                        new ToolContext(Map.of(TurnoContexto.CLAVE, new TurnoContexto(List.of(DEFINIR)))));

        assertThat(salida).contains("\"definicion\"").contains("Contrato: Define el instrumento")
                .contains("actividad_escala_definir: claves tipoEscala, valorMax, valorMin")
                .contains("rechaza si: La escala numérica");
    }

    @Test
    void sinLaBaseQuedanElEsquemaYElContratoYUnaHerramientaAjenaNoSeDescribe() {
        EstructuraEndpoint caida = id -> {
            throw new IllegalStateException("sin base");
        };
        EstructuraEsperadaHerramienta herramienta = new EstructuraEsperadaHerramienta(caida);
        ToolContext contexto = new ToolContext(Map.of(TurnoContexto.CLAVE, new TurnoContexto(List.of(DEFINIR))));

        assertThat(herramienta.callbacks().get(0).call("{\"codigo\":\"actualizar_instrumento_actividad\"}", contexto))
                .contains("Contrato:").doesNotContain("Lo que lee");
        assertThat(herramienta.callbacks().get(0).call("{\"codigo\":\"borrar_todo\"}", contexto))
                .isEqualTo(EsquemaDeAccionHerramienta.NO_DISPONIBLE);
    }
}
