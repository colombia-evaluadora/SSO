package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import com.co.eurekatic.aicontrol.agente.memoria.NotaDeMemoria;
import com.co.eurekatic.aicontrol.agente.nucleo.Faltante;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.AccionUi;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import com.co.eurekatic.aicontrol.agente.persistencia.herramienta.ToolInvocacionStore;
import com.co.eurekatic.aicontrol.agente.persistencia.mensaje.MensajeStore;
import com.co.eurekatic.aicontrol.agente.persistencia.mensaje.RolMensaje;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.ai.chat.memory.ChatMemory;
import org.springframework.ai.chat.messages.AssistantMessage;
import org.springframework.ai.chat.messages.Message;
import org.springframework.ai.chat.messages.ToolResponseMessage;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class RegistradorTurnoTest {

    private static final UUID CONVERSACION = UUID.randomUUID();

    private static MensajeStore.Mensaje mensaje(int secuencia, RolMensaje rol, String contenido) {
        return new MensajeStore.Mensaje(secuencia, CONVERSACION, secuencia, rol, contenido, null, null,
                LocalDateTime.of(2026, 10, 14, 10, 0));
    }

    @Test
    void loDichoPorLaPersonaSonTodosSusMensajesNoSoloElUltimo() {
        MensajeStore mensajes = mock(MensajeStore.class);
        when(mensajes.listar(CONVERSACION)).thenReturn(List.of(
                mensaje(1, RolMensaje.USER, "Deja solo a Brayan Alfaro y a Luis Castro."),
                mensaje(2, RolMensaje.ASSISTANT, "No encuentro a Luis Castro."),
                mensaje(3, RolMensaje.USER, "Usa los valores por defecto.")));

        String dicho = new RegistradorTurno(mock(ChatMemory.class), mensajes, mock(ToolInvocacionStore.class))
                .dichoPorLaPersona(CONVERSACION);

        assertThat(dicho).contains("Brayan Alfaro", "Usa los valores por defecto").doesNotContain("No encuentro");
    }

    @Test
    void unaPreguntaVuelveALaMemoriaConLoQuePreguntoNoConSuTextoGenerico() {
        RespuestaAgente.Pregunta pregunta = new RespuestaAgente.Pregunta(NotaDeMemoria.TEXTO_PREGUNTA,
                List.of(new Faltante("tipo_actividad", "¿Qué tipo de actividad es?", List.of("Tarea", "Trabajo en clase"))),
                Map.of());

        String texto = RegistradorTurno.textoParaMemoria(pregunta);

        assertThat(texto).isEqualTo("tipo_actividad: ¿Qué tipo de actividad es? (opciones: Tarea, Trabajo en clase)");
        assertThat(NotaDeMemoria.para("PREGUNTA", texto))
                .startsWith("[Pregunta enviada a la persona: tipo_actividad")
                .doesNotContain(NotaDeMemoria.TEXTO_PREGUNTA);
        assertThat(NotaDeMemoria.para("PREGUNTA", NotaDeMemoria.TEXTO_PREGUNTA))
                .as("una fila antigua de la base solo trae el texto generico")
                .startsWith("[Pregunta enviada a la persona").doesNotContain(NotaDeMemoria.TEXTO_PREGUNTA);
    }

    @Test
    void lasAccionesDeUiSeGuardanEnLaBaseYLaMemoriaRecuerdaCadaCampo() {
        MensajeStore mensajes = mock(MensajeStore.class);
        ChatMemory memoria = mock(ChatMemory.class);
        RespuestaAgente.Ui ui = new RespuestaAgente.Ui("Listo, rellené los datos.", List.of(
                new AccionUi.Rellenar("funcionario.crear", Map.of("cargo", "COORDINADOR")),
                new AccionUi.Resaltar("funcionario.crear", "fecha_ingreso")));

        new RegistradorTurno(memoria, mensajes, mock(ToolInvocacionStore.class))
                .registrar(CONVERSACION, ui, Consumo.NINGUNO, 30L);

        ArgumentCaptor<MensajeStore.NuevoMensaje> guardado = ArgumentCaptor.forClass(MensajeStore.NuevoMensaje.class);
        verify(mensajes).insertar(eq(CONVERSACION), guardado.capture());
        String json = guardado.getValue().accionesUiJson();
        assertThat(json).contains("\"op\":\"RELLENAR\"", "\"cargo\":\"COORDINADOR\"", "\"op\":\"RESALTAR\"");
        String nota = "[Cambios enviados a la pantalla: rellenar cargo=COORDINADOR; resaltar fecha_ingreso. "
                + "Texto mostrado: Listo, rellené los datos.]";
        ArgumentCaptor<List<Message>> turno = ArgumentCaptor.forClass(List.class);
        verify(memoria).add(eq(CONVERSACION.toString()), turno.capture());
        assertThat(turno.getValue()).singleElement().satisfies(m -> assertThat(m.getText()).isEqualTo(nota));
        assertThat(NotaDeMemoria.para("UI", "Listo, rellené los datos.", json))
                .as("la memoria reconstruida desde la base dice lo mismo").isEqualTo(nota);
        assertThat(NotaDeMemoria.para("UI", "Listo.", "no es json"))
                .isEqualTo("[Cambios enviados a la pantalla. Texto mostrado: Listo.]");
    }

    @Test
    void alCerrarElTurnoLaMemoriaRecibeSusLlamadasAntesDeLaRespuesta() {
        MensajeStore mensajes = mock(MensajeStore.class);
        ToolInvocacionStore invocaciones = mock(ToolInvocacionStore.class);
        ChatMemory memoria = mock(ChatMemory.class);
        when(invocaciones.listarPorConversacion(CONVERSACION)).thenReturn(List.of(
                new ToolInvocacionStore.Invocacion(7L, 30L, "actividad_detalle", null, "OK: 1 filas"),
                new ToolInvocacionStore.Invocacion(8L, 31L, "otra_del_turno_siguiente", null, "OK: 2 filas")));
        RegistradorTurno registrador = new RegistradorTurno(memoria, mensajes, invocaciones);

        registrador.registrar(CONVERSACION, new RespuestaAgente.Respuesta("Son 15."), Consumo.NINGUNO, 30L);

        ArgumentCaptor<List<Message>> turno = ArgumentCaptor.forClass(List.class);
        verify(memoria).add(eq(CONVERSACION.toString()), turno.capture());
        assertThat(turno.getValue()).hasSize(3);
        assertThat(((AssistantMessage) turno.getValue().get(0)).getToolCalls())
                .extracting(AssistantMessage.ToolCall::name).containsExactly("actividad_detalle");
        assertThat(turno.getValue().get(1)).isInstanceOf(ToolResponseMessage.class);
        assertThat(turno.getValue().get(2).getText()).isEqualTo("Son 15.");

        registrador.registrar(CONVERSACION, new RespuestaAgente.Respuesta("Hecho: Edita 7"), Consumo.NINGUNO);
        verify(memoria, times(2)).add(eq(CONVERSACION.toString()), turno.capture());
        assertThat(turno.getValue()).as("confirmar no tiene llamadas del turno").singleElement()
                .satisfies(m -> assertThat(m.getText()).isEqualTo("[Accion ejecutada tras confirmar: Edita 7]"));
    }

    @Test
    void guardaLaRespuestaEnteraConLaAccionPendienteYLosFaltantes() {
        UUID accion = UUID.randomUUID();
        String confirmacion = RegistradorTurno.respuestaJson(new RespuestaAgente.Confirmacion("Confirma",
                new com.co.eurekatic.aicontrol.agente.nucleo.AccionPropuesta(accion, "Editar a Persona_1",
                        LocalDateTime.of(2026, 10, 16, 10, 0, 5))), null);
        assertThat(confirmacion).contains("\"tipo\":\"CONFIRMACION\"", "\"id\":\"" + accion + "\"",
                "\"resumen\":\"Editar a Persona_1\"", "\"expira\":\"2026-10-16T10:00:05\"");

        String pregunta = RegistradorTurno.respuestaJson(new RespuestaAgente.Pregunta("Falta un dato",
                List.of(new Faltante("sede", "¿Qué sede?", List.of("Norte"))), Map.of()), null);
        assertThat(pregunta).contains("\"faltantes\":[{\"campo\":\"sede\"", "\"opciones\":[\"Norte\"]");
    }
}
