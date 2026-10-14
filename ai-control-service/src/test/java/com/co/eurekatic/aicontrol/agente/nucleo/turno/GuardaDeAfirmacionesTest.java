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
        assertThat(GuardaDeAfirmaciones.revisar(new RespuestaAgente.Respuesta(
                "Voy a buscar tus grupos.<tool_call>\n<tool name=\"consultar_grupos\">\n</tool>")).texto())
                .as("llamada escrita como texto").isEqualTo(GuardaDeAfirmaciones.SIN_HERRAMIENTA);
        assertThat(GuardaDeAfirmaciones.revisar(new RespuestaAgente.Respuesta("Voy a consultar.\n{\"name\": "
                + "\"estructura_esperada\", \"input\": {\"entidad\": \"instrumento\"}}")).texto())
                .as("llamada escrita como JSON").isEqualTo(GuardaDeAfirmaciones.SIN_HERRAMIENTA);
        assertThat(GuardaDeAfirmaciones.objecion(new RespuestaAgente.Respuesta("<invoke name=\"x\">")))
                .hasValueSatisfying(o -> assertThat(o).contains("interfaz de herramientas"));
        assertThat(GuardaDeAfirmaciones.revisar(new RespuestaAgente.Respuesta(
                "Hecho: Califica a UN estudiante (Pk del estudiante en la actividad: 2763).")).texto())
                .as("copia el formato del resultado de una confirmacion").isEqualTo(GuardaDeAfirmaciones.SIN_ACCION);
        assertThat(List.of("Listo: ya preparé el cambio de la fecha.", "Ya dejé preparada la edición."))
                .allSatisfy(t -> assertThat(GuardaDeAfirmaciones.revisar(new RespuestaAgente.Respuesta(t)).texto())
                        .as(t).isEqualTo(GuardaDeAfirmaciones.SIN_ACCION));
        assertThat(NotaDeMemoria.para("RESPUESTA", "Hecho: Registra la asistencia."))
                .isEqualTo("La persona confirmo y el sistema ejecuto: Registra la asistencia.");
        assertThat(GuardaDeAfirmaciones.objecion(new RespuestaAgente.Respuesta("Para continuar necesito estos datos.")))
                .as("el aviso de datos faltantes sin la herramienta").contains(GuardaDeAfirmaciones.PREGUNTA_SIN_HERRAMIENTA);
        assertThat(List.of("Para seguir necesito estos datos.", "Para poder avanzar, necesito los siguientes datos:",
                "Pedi a la persona con la herramienta pedir_datos_faltantes los datos que faltaban."))
                .allSatisfy(x -> assertThat(GuardaDeAfirmaciones.objecion(new RespuestaAgente.Respuesta(x)))
                        .as(x).contains(GuardaDeAfirmaciones.PREGUNTA_SIN_HERRAMIENTA));
        assertThat(NotaDeMemoria.para("RESPUESTA", "Datos no validos para el servicio academico: indique el peso (%)"))
                .startsWith("La persona confirmo la accion anterior pero el servicio la rechazo")
                .contains("vuelve a llamar a la misma herramienta");
        RespuestaAgente impersonal = new RespuestaAgente.Respuesta(
                "La fecha de cierre del Taller se actualizó al 30 de octubre de 2026.");
        assertThat(GuardaDeAfirmaciones.objecion(impersonal)).as("un cambio contado como hecho sin escritura")
                .contains(GuardaDeAfirmaciones.CAMBIO_SIN_ESCRITURA);
        assertThat(GuardaDeAfirmaciones.objecion(new RespuestaAgente.Respuesta("Las notas quedaron registradas.")))
                .contains(GuardaDeAfirmaciones.CAMBIO_SIN_ESCRITURA);
        RespuestaAgente historico = new RespuestaAgente.Respuesta("La actividad se creó el 2026-10-01 y cierra el 27.");
        assertThat(GuardaDeAfirmaciones.revisar(historico)).as("un dato historico no se sustituye si el modelo lo mantiene")
                .isSameAs(historico);
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
    void ofrecerConsultarEnVezDeHacerloSeObjetaPeroNoSeSustituye() {
        RespuestaAgente ofrece = new RespuestaAgente.Respuesta(
                "Para ver los detalles, revísela en su pantalla. Si quiere, puedo consultarla y resumirle el instrumento.");

        assertThat(GuardaDeAfirmaciones.objecion(ofrece)).contains(GuardaDeAfirmaciones.CONSULTA_EN_VEZ_DE_OFRECER);
        assertThat(GuardaDeAfirmaciones.revisar(ofrece)).as("si insiste, es honesto").isSameAs(ofrece);
        assertThat(GuardaDeAfirmaciones.objecion(new RespuestaAgente.Respuesta("Tiene 15 estudiantes asignados.")))
                .isEmpty();
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
