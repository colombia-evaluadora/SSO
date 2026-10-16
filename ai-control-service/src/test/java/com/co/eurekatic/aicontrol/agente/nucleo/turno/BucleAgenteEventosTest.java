package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import org.junit.jupiter.api.Test;
import org.springframework.ai.tool.ToolCallback;
import org.springframework.ai.tool.definition.ToolDefinition;

import java.util.ArrayList;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class BucleAgenteEventosTest {

    @Test
    void cadaHerramientaAvisaInicioYFinSinArgumentos() {
        List<EventoHerramienta> eventos = new ArrayList<>();
        ObservadorTurno observador = new ObservadorTurno() {
            @Override
            public void alPasar(EstadoTurno estado) {
            }

            @Override
            public void alHerramienta(EventoHerramienta evento) {
                eventos.add(evento);
            }
        };
        List<ToolCallback> envueltas = BucleAgente.conEventos(List.of(herramienta("sedes_listar", false),
                herramienta("funcionario_detalle", true)), observador);

        assertThat(envueltas.get(0).call("{\"documento\":\"123\"}")).isEqualTo("ok");
        assertThatThrownBy(() -> envueltas.get(1).call("{}")).isInstanceOf(IllegalStateException.class);

        assertThat(eventos).extracting(EventoHerramienta::id, EventoHerramienta::herramienta,
                        e -> e.fase().name(), EventoHerramienta::ok)
                .containsExactly(
                        org.assertj.core.groups.Tuple.tuple("h1", "sedes_listar", "INICIO", null),
                        org.assertj.core.groups.Tuple.tuple("h1", "sedes_listar", "FIN", true),
                        org.assertj.core.groups.Tuple.tuple("h2", "funcionario_detalle", "INICIO", null),
                        org.assertj.core.groups.Tuple.tuple("h2", "funcionario_detalle", "FIN", false));
        assertThat(eventos).allMatch(e -> !e.etiqueta().contains("123"));
    }

    @Test
    void sinObservadorLasHerramientasNoSeEnvuelven() {
        List<ToolCallback> originales = List.of(herramienta("sedes_listar", false));
        assertThat(BucleAgente.conEventos(originales, ObservadorTurno.NINGUNO)).isSameAs(originales);
    }

    private static ToolCallback herramienta(String nombre, boolean falla) {
        ToolDefinition definicion = ToolDefinition.builder().name(nombre).description(nombre).inputSchema("{}").build();
        return new ToolCallback() {
            @Override
            public ToolDefinition getToolDefinition() {
                return definicion;
            }

            @Override
            public String call(String toolInput) {
                if (falla) {
                    throw new IllegalStateException("fallo");
                }
                return "ok";
            }
        };
    }
}
