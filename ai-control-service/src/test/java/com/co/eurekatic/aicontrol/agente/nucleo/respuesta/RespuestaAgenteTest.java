package com.co.eurekatic.aicontrol.agente.nucleo.respuesta;

import com.co.eurekatic.aicontrol.agente.nucleo.AccionPropuesta;
import com.co.eurekatic.aicontrol.agente.nucleo.Faltante;
import org.junit.jupiter.api.Test;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class RespuestaAgenteTest {

    @Test
    void cadaRespuestaDeclaraSuTipo() {
        AccionPropuesta accion = new AccionPropuesta(UUID.randomUUID(), "Crear X", LocalDateTime.now());

        assertThat(new RespuestaAgente.Respuesta("hola").tipo()).isEqualTo(TipoRespuesta.RESPUESTA);
        assertThat(new RespuestaAgente.Pregunta("¿?", List.of(), Map.of()).tipo()).isEqualTo(TipoRespuesta.PREGUNTA);
        assertThat(new RespuestaAgente.Confirmacion("¿Confirmas?", accion).tipo()).isEqualTo(TipoRespuesta.CONFIRMACION);
        assertThat(new RespuestaAgente.Ui("abro", List.of()).tipo()).isEqualTo(TipoRespuesta.UI);
        assertThat(new RespuestaAgente.Datos("ok", List.of(), List.of()).tipo()).isEqualTo(TipoRespuesta.DATOS);
        assertThat(new RespuestaAgente.Bloqueado("no").tipo()).isEqualTo(TipoRespuesta.BLOQUEADO);
        assertThat(new RespuestaAgente.SinPermiso("no").tipo()).isEqualTo(TipoRespuesta.SIN_PERMISO);
    }

    @Test
    void transformarTextosReescribeTambienLasPreguntasDelFaltante() {
        RespuestaAgente pregunta = new RespuestaAgente.Pregunta("Necesito datos",
                List.of(new Faltante("jornada", "¿Jornada?", List.of("MAÑANA"))), Map.of("nombres", "Ana"));

        RespuestaAgente transformada = pregunta.transformarTextos(t -> t.replace("¿", "¡"));

        assertThat(transformada).isInstanceOfSatisfying(RespuestaAgente.Pregunta.class, p -> {
            assertThat(p.texto()).isEqualTo("Necesito datos");
            assertThat(p.faltantes().get(0).pregunta()).isEqualTo("¡Jornada?");
            assertThat(p.faltantes().get(0).opciones()).containsExactly("MAÑANA");
            assertThat(p.borrador()).containsEntry("nombres", "Ana");
        });
    }

    @Test
    void elBorradorNoAdmiteNulos() {
        Map<String, Object> conNulo = new java.util.HashMap<>();
        conNulo.put("sede", null);

        org.assertj.core.api.Assertions.assertThatThrownBy(() -> new RespuestaAgente.Pregunta("x", List.of(), conNulo))
                .isInstanceOf(NullPointerException.class);
    }
}
