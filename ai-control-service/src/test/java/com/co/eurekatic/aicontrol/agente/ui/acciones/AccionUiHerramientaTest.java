package com.co.eurekatic.aicontrol.agente.ui.acciones;

import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.ContextoInvocacion;
import com.co.eurekatic.aicontrol.agente.nucleo.TurnoContexto;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.AccionUi;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import com.co.eurekatic.aicontrol.agente.seguridad.CapaSeguridad;
import com.co.eurekatic.aicontrol.agente.seguridad.eventos.EventoSeguridadService;
import com.co.eurekatic.aicontrol.agente.ui.UiFixture;
import com.co.eurekatic.aicontrol.agente.ui.registro.RegistroUiLoader;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.ai.chat.model.ToolContext;

import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class AccionUiHerramientaTest {

    private final RegistroUiLoader registro = mock(RegistroUiLoader.class);
    private final ResolutorConfiguracionDb resolutor = mock(ResolutorConfiguracionDb.class);
    private final EventoSeguridadService eventos = mock(EventoSeguridadService.class);
    private final AccionUiHerramienta herramienta = new AccionUiHerramienta(registro, resolutor, eventos);
    private TurnoContexto turno;
    private ToolContext contexto;

    @BeforeEach
    void setUp() {
        when(registro.registro()).thenReturn(UiFixture.REGISTRO);
        turno = new TurnoContexto(List.of(), UiFixture.CONTEXTO, UiFixture.MENUS_DOCENTE);
        ContextoInvocacion invocacion = new ContextoInvocacion(7L, "token", UUID.randomUUID().toString(), 1L,
                "llena el formulario", propuesta -> {
                });
        contexto = new ToolContext(Map.of(TurnoContexto.CLAVE, turno, ContextoInvocacion.CLAVE, invocacion));
    }

    @Test
    void accionesValidasTerminanElTurnoConUnaRespuestaDeUi() {
        String acuse = herramienta.ejecutar(Map.of("texto", "Llené lo que me diste", "acciones", List.of(
                Map.of("op", "RELLENAR", "formulario", "funcionario.crear", "valores", Map.of("nombres", "Ana")),
                Map.of("op", "RESALTAR", "formulario", "funcionario.crear", "campo", "cargo"))), contexto);

        assertThat(acuse).isEqualTo(AccionUiHerramienta.ACUSE);
        assertThat(turno.directa()).get().isInstanceOfSatisfying(RespuestaAgente.Ui.class, ui -> {
            assertThat(ui.texto()).isEqualTo("Llené lo que me diste");
            assertThat(ui.acciones()).containsExactly(
                    new AccionUi.Rellenar("funcionario.crear", Map.of("nombres", "Ana")),
                    new AccionUi.Resaltar("funcionario.crear", "cargo"));
        });
        verify(eventos, never()).registrar(any());
    }

    @Test
    void siNingunaAccionValeNoRespondeYQuedaUnEventoDeSeguridad() {
        String resultado = herramienta.ejecutar(Map.of("texto", "x", "acciones", List.of(
                Map.of("op", "NAVEGAR", "pantalla", "config_roles_menus"))), contexto);

        assertThat(resultado).startsWith("Ninguna accion es valida");
        assertThat(turno.directa()).isEmpty();
        ArgumentCaptor<EventoSeguridadService.RegistroEvento> evento =
                ArgumentCaptor.forClass(EventoSeguridadService.RegistroEvento.class);
        verify(eventos).registrar(evento.capture());
        assertThat(evento.getValue().hallazgo().capa()).isEqualTo(CapaSeguridad.UI);
        assertThat(evento.getValue().fkUsuario()).isEqualTo(7L);
    }

    @Test
    void unFormularioDeLaBaseUsaSuConfiguracionYFallaCerradoSinElla() {
        when(resolutor.resolver(any(), any(), any())).thenReturn(Optional.empty());

        String sinConfig = herramienta.ejecutar(Map.of("acciones", List.of(Map.of("op", "RELLENAR",
                "formulario", "planeador.actividad", "valores", Map.of("titulo", "Fracciones")))), contexto);

        assertThat(sinConfig).startsWith("Ninguna accion es valida");

        when(resolutor.resolver(any(), any(), any())).thenReturn(Optional.of(ConfiguracionCamposDb.sinRestricciones()));

        herramienta.ejecutar(Map.of("acciones", List.of(Map.of("op", "RELLENAR",
                "formulario", "planeador.actividad", "valores", Map.of("titulo", "Fracciones")))), contexto);

        assertThat(turno.directa()).get().isInstanceOfSatisfying(RespuestaAgente.Ui.class,
                ui -> assertThat(ui.texto()).isEqualTo(AccionUiHerramienta.TEXTO_POR_DEFECTO));
    }
}
