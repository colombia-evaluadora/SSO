package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import com.co.eurekatic.aicontrol.agente.memoria.NotaDeMemoria;
import com.co.eurekatic.aicontrol.agente.nucleo.Faltante;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import com.co.eurekatic.aicontrol.agente.persistencia.mensaje.MensajeStore;
import com.co.eurekatic.aicontrol.agente.persistencia.mensaje.RolMensaje;
import org.junit.jupiter.api.Test;
import org.springframework.ai.chat.memory.ChatMemory;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
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

        String dicho = new RegistradorTurno(mock(ChatMemory.class), mensajes).dichoPorLaPersona(CONVERSACION);

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
                .startsWith("Pedi a la persona con la herramienta pedir_datos_faltantes: tipo_actividad")
                .doesNotContain(NotaDeMemoria.TEXTO_PREGUNTA);
        assertThat(NotaDeMemoria.para("PREGUNTA", NotaDeMemoria.TEXTO_PREGUNTA))
                .as("una fila antigua de la base solo trae el texto generico")
                .startsWith("Pedi a la persona").doesNotContain(NotaDeMemoria.TEXTO_PREGUNTA);
    }
}
