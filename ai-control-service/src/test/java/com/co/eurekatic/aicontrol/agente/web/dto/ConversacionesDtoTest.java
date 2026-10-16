package com.co.eurekatic.aicontrol.agente.web.dto;

import com.co.eurekatic.aicontrol.agente.persistencia.accion.EstadoAccion;
import com.co.eurekatic.aicontrol.agente.persistencia.mensaje.MensajeStore.Mensaje;
import com.co.eurekatic.aicontrol.agente.persistencia.mensaje.RolMensaje;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.JsonNode;

import java.time.LocalDateTime;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class ConversacionesDtoTest {

    private static final UUID CONVERSACION = UUID.randomUUID();
    private static final LocalDateTime AHORA = LocalDateTime.of(2026, 10, 16, 9, 0);

    @Test
    void laAccionPendienteDelHistorialLlevaSuEstadoActual() {
        UUID accion = UUID.randomUUID();
        Mensaje m = new Mensaje(2L, CONVERSACION, 2, RolMensaje.ASSISTANT, "Confirma", "CONFIRMACION", null, AHORA,
                "{\"tipo\":\"CONFIRMACION\",\"texto\":\"Confirma\",\"accionPendiente\":{\"id\":\"" + accion
                        + "\",\"resumen\":\"Editar\",\"expira\":\"2026-10-16T09:10:00\"}}");

        JsonNode pendiente = ConversacionesDto.MensajeDto.de(m, Map.of(accion, EstadoAccion.PENDIENTE)).respuesta();
        JsonNode ejecutada = ConversacionesDto.MensajeDto.de(m, Map.of(accion, EstadoAccion.EJECUTADA)).respuesta();
        JsonNode desconocida = ConversacionesDto.MensajeDto.de(m, Map.of()).respuesta();

        assertThat(pendiente.path("accionPendiente").path("estado").asString()).isEqualTo("PENDIENTE");
        assertThat(pendiente.path("accionPendiente").path("resumen").asString()).isEqualTo("Editar");
        assertThat(ejecutada.path("accionPendiente").path("estado").asString()).isEqualTo("EJECUTADA");
        assertThat(desconocida.path("accionPendiente").path("estado").asString()).isEqualTo("EXPIRADA");
    }

    @Test
    void unMensajeAntiguoSeArmaConTipoTextoYAccionesYElDeLaPersonaNoLleva() {
        Mensaje viejo = new Mensaje(2L, CONVERSACION, 2, RolMensaje.ASSISTANT, "Listo", "UI",
                "[{\"op\":\"ABRIR_PESTANA\",\"pestana\":\"Notas\"}]", AHORA);
        Mensaje usuario = new Mensaje(1L, CONVERSACION, 1, RolMensaje.USER, "hola", null, null, AHORA);

        JsonNode respuesta = ConversacionesDto.MensajeDto.de(viejo).respuesta();

        assertThat(respuesta.path("tipo").asString()).isEqualTo("UI");
        assertThat(respuesta.path("texto").asString()).isEqualTo("Listo");
        assertThat(respuesta.path("acciones").get(0).path("op").asString()).isEqualTo("ABRIR_PESTANA");
        assertThat(ConversacionesDto.MensajeDto.de(usuario).respuesta()).isNull();
    }
}
