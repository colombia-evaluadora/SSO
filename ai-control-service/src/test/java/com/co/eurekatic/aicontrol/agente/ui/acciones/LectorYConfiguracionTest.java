package com.co.eurekatic.aicontrol.agente.ui.acciones;

import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.AccionUi;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;

class LectorYConfiguracionTest {

    @Test
    void leeCadaOpYReportaLasQueNoTienenForma() {
        LectorAccionesUi.Lectura lectura = LectorAccionesUi.leer(List.of(
                Map.of("op", "NAVEGAR", "pantalla", "planeador", "params", Map.of("id", 5)),
                Map.of("op", "RELLENAR", "formulario", "f", "valores", Map.of("a", "1", "anidado", Map.of("x", 1))),
                Map.of("op", "RESALTAR", "formulario", "f", "campo", "b"),
                Map.of("op", "ENVIAR", "formulario", "f"),
                Map.of("pantalla", "sin op")));

        assertThat(lectura.acciones()).containsExactly(
                new AccionUi.Navegar("planeador", "", Map.of("id", "5")),
                new AccionUi.Rellenar("f", Map.of("a", "1")),
                new AccionUi.Resaltar("f", "b"));
        assertThat(lectura.errores()).hasSize(2).anySatisfy(e -> assertThat(e).contains("ENVIAR"));
    }

    @Test
    void conUnSoloFormularioAbiertoLasAccionesQueNoLoNombranSonSobreEl() {
        LectorAccionesUi.Lectura lectura = LectorAccionesUi.leer(List.of(
                Map.of("op", "RESALTAR", "campo", "cargo"),
                Map.of("op", "RELLENAR", "valores", Map.of("nombres", "Ana"))), Optional.of("funcionario.crear"));

        assertThat(lectura.acciones()).containsExactly(
                new AccionUi.Resaltar("funcionario.crear", "cargo"),
                new AccionUi.Rellenar("funcionario.crear", Map.of("nombres", "Ana")));
        assertThat(LectorAccionesUi.leer(List.of(Map.of("op", "RESALTAR", "campo", "cargo"))).errores())
                .as("sin formulario unico").singleElement().asString().contains("RESALTAR con claves").contains("campo");
    }

    @Test
    void sinAccionesEsUnError() {
        assertThat(LectorAccionesUi.leer(null).errores()).hasSize(1);
        assertThat(LectorAccionesUi.leer(List.of()).acciones()).isEmpty();
    }

    @Test
    void laConfiguracionDeLaBaseSeLeeAnidadaYComoTextoJson() {
        ConfiguracionCamposDb config = ConfiguracionCamposDb.desde(List.of(Map.of(
                "configuracion", "{\"recuperacion\":{\"visible\":false},\"criterio\":{\"visible\":true}}",
                "evaluacion", Map.of("ponderacion", Map.of("visible", "false")))));

        assertThat(config.oculta("recuperacion_fecha")).isTrue();
        assertThat(config.oculta("Ponderación")).isTrue();
        assertThat(config.oculta("criterioId")).isFalse();
        assertThat(config.oculta("titulo")).isFalse();
    }

    @Test
    void sinRestriccionesNoOcultaNada() {
        assertThat(ConfiguracionCamposDb.sinRestricciones().oculta("recuperacion")).isFalse();
    }
}
