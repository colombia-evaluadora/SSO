package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import com.co.eurekatic.aicontrol.agente.memoria.NotaDeMemoria;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.AccionUi;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class GuardaDeAfirmacionesTest {

    @Test
    void unTextoQueImitaUnaConfirmacionOUnCambioHechoSeSustituye() {
        assertThat(GuardaDeAfirmaciones.revisar(new RespuestaAgente.Respuesta(
                "Antes de hacerlo necesito tu confirmación: Edita la actividad")).texto())
                .isEqualTo(GuardaDeAfirmaciones.SIN_ACCION);
        assertThat(GuardaDeAfirmaciones.revisar(new RespuestaAgente.Respuesta(
                "Listo: actualicé el título a **Repaso**.")).texto())
                .isEqualTo(GuardaDeAfirmaciones.SIN_PANTALLA);
        assertThat(GuardaDeAfirmaciones.revisar(new RespuestaAgente.Respuesta(
                NotaDeMemoria.para("CONFIRMACION", NotaDeMemoria.PREFIJO_CONFIRMACION + "Editar 7"))).texto())
                .as("imita la nota de una confirmacion").isEqualTo(GuardaDeAfirmaciones.SIN_ACCION);
        assertThat(GuardaDeAfirmaciones.revisar(new RespuestaAgente.Respuesta(
                NotaDeMemoria.para("UI", "Te llevo a Funcionarios."))).texto())
                .as("imita la nota de UI").isEqualTo(GuardaDeAfirmaciones.SIN_PANTALLA);
        assertThat(GuardaDeAfirmaciones.revisar(new RespuestaAgente.Respuesta(
                "La actividad ya está preparada y espera tu confirmación para crearse.")).texto())
                .isEqualTo(GuardaDeAfirmaciones.SIN_ACCION);
        assertThat(GuardaDeAfirmaciones.revisar(new RespuestaAgente.Respuesta("[Sistema: algo]")).texto())
                .isEqualTo(GuardaDeAfirmaciones.SIN_PANTALLA);
        assertThat(List.of(
                "No puedo enviar formularios. Lo que sí hice fue rellenar el nombre con Luis.",
                "He rellenado el nombre.",
                "Ya puse el título en la pantalla."))
                .allSatisfy(t -> assertThat(GuardaDeAfirmaciones.revisar(new RespuestaAgente.Respuesta(t)).texto())
                        .as(t).isEqualTo(GuardaDeAfirmaciones.SIN_PANTALLA));
        assertThat(GuardaDeAfirmaciones.revisar(new RespuestaAgente.Respuesta(
                "Rellene usted el campo cargo y pulse Guardar.")).texto())
                .as("un imperativo no es una afirmacion").isEqualTo("Rellene usted el campo cargo y pulse Guardar.");
    }

    @Test
    void lasRespuestasNormalesYLasDeUiPasanIntactas() {
        RespuestaAgente normal = new RespuestaAgente.Respuesta("El colegio tiene 4 sedes. Listo para ayudarte.");
        RespuestaAgente ui = new RespuestaAgente.Ui("Listo: rellené el nombre.",
                List.of(new AccionUi.Rellenar("funcionario.crear", Map.of("nombres", "Ana"))));

        assertThat(GuardaDeAfirmaciones.revisar(normal)).isSameAs(normal);
        assertThat(GuardaDeAfirmaciones.revisar(ui)).isSameAs(ui);
    }

    @Test
    void laMemoriaGuardaConfirmacionesYUiComoNotasDelSistema() {
        assertThat(NotaDeMemoria.para("CONFIRMACION", NotaDeMemoria.PREFIJO_CONFIRMACION + "Editar la actividad 7"))
                .startsWith("Prepare con la herramienta").contains("Editar la actividad 7")
                .doesNotContain("necesito tu confirmación");
        assertThat(NotaDeMemoria.para("UI", "Listo: rellené el nombre.")).startsWith("Envie acciones a la pantalla");
        assertThat(NotaDeMemoria.para("RESPUESTA", "Hola")).isEqualTo("Hola");
        assertThat(NotaDeMemoria.para(null, "Hola")).isEqualTo("Hola");
    }
}
