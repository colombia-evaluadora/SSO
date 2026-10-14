package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import com.co.eurekatic.aicontrol.agente.comun.ErrorAgente;
import com.co.eurekatic.aicontrol.agente.comun.UsuarioAgente;
import com.co.eurekatic.aicontrol.agente.nucleo.intencion.Intencion;
import com.co.eurekatic.aicontrol.agente.nucleo.intencion.RouterIntencion;
import com.co.eurekatic.aicontrol.agente.nucleo.intencion.TipoIntencion;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import com.co.eurekatic.aicontrol.agente.persistencia.mensaje.MensajeStore;
import com.co.eurekatic.aicontrol.agente.persistencia.mensaje.RolMensaje;
import com.co.eurekatic.aicontrol.agente.seguridad.CapaSeguridad;
import com.co.eurekatic.aicontrol.agente.seguridad.Hallazgo;
import com.co.eurekatic.aicontrol.agente.seguridad.Motivo;
import com.co.eurekatic.aicontrol.agente.seguridad.Riesgo;
import com.co.eurekatic.aicontrol.agente.seguridad.entrada.Evaluacion;
import com.co.eurekatic.aicontrol.agente.seguridad.entrada.EvaluadorEntrada;
import com.co.eurekatic.aicontrol.agente.seguridad.eventos.EventoSeguridadService;
import com.co.eurekatic.aicontrol.agente.seguridad.limite.LimitadorPorUsuario;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class PreparadorTurnoTest {

    private static final UsuarioAgente USUARIO = new UsuarioAgente(7L, Set.of("DOCENTE"), "token");
    private static final UUID CONVERSACION = UUID.randomUUID();

    private final LimitadorPorUsuario limitador = mock(LimitadorPorUsuario.class);
    private final EvaluadorEntrada evaluador = mock(EvaluadorEntrada.class);
    private final RouterIntencion router = mock(RouterIntencion.class);
    private final SelectorHerramientas selector = mock(SelectorHerramientas.class);
    private final EventoSeguridadService eventos = mock(EventoSeguridadService.class);
    private final MensajeStore mensajes = mock(MensajeStore.class);
    private final PreparadorTurno preparador = new PreparadorTurno(limitador, evaluador, router, selector, eventos,
            mensajes);

    private static MensajeStore.Mensaje asistente(String tipo, String contenido) {
        return new MensajeStore.Mensaje(1L, CONVERSACION, 2, RolMensaje.ASSISTANT, contenido, tipo, null, null);
    }

    @Test
    void trasUnaPreguntaOUnaConfirmacionFallidaLaRespuestaSigueLaAccion() {
        Intencion charla = new Intencion(TipoIntencion.CHARLA, "", 0.6, Riesgo.BAJO);

        when(mensajes.listarFinales(CONVERSACION)).thenReturn(List.of(asistente("PREGUNTA", "Para continuar...")));
        assertThat(preparador.continuacion(CONVERSACION, charla).tipo()).isEqualTo(TipoIntencion.ACCION);

        when(mensajes.listarFinales(CONVERSACION)).thenReturn(List.of(asistente("RESPUESTA",
                "Datos no validos para el servicio academico: indique el peso (%)")));
        Intencion siguiente = preparador.continuacion(CONVERSACION, charla);
        assertThat(siguiente.tipo()).isEqualTo(TipoIntencion.ACCION);
        assertThat(siguiente.riesgo()).isEqualTo(Riesgo.BAJO);
    }

    @Test
    void unaRespuestaSueltaEntreMediasNoCortaLaAccionEnCurso() {
        Intencion charla = new Intencion(TipoIntencion.CHARLA, "", 0.6, Riesgo.BAJO);
        when(mensajes.listarFinales(CONVERSACION)).thenReturn(List.of(
                asistente("RESPUESTA", "Datos no validos para el servicio academico: tipo esperado bigint"),
                asistente("RESPUESTA", "La persona decidio: {niveles=...}"),
                asistente("RESPUESTA", "Voy a consultar.\n{\"name\": \"estructura_esperada\", \"input\": {}}")));

        assertThat(preparador.continuacion(CONVERSACION, charla).tipo()).isEqualTo(TipoIntencion.ACCION);
    }

    @Test
    void sinAccionEnCursoOConOtraIntencionNoCambiaNada() {
        Intencion charla = new Intencion(TipoIntencion.CHARLA, "", 0.6, Riesgo.BAJO);
        when(mensajes.listarFinales(CONVERSACION)).thenReturn(List.of(asistente("RESPUESTA", "Hay 3 sedes.")));
        assertThat(preparador.continuacion(CONVERSACION, charla).tipo()).isEqualTo(TipoIntencion.CHARLA);

        when(mensajes.listarFinales(CONVERSACION)).thenReturn(List.of(asistente("PREGUNTA", "¿Cuál?")));
        Intencion analitica = new Intencion(TipoIntencion.ANALITICA, "", 0.9, Riesgo.BAJO);
        assertThat(preparador.continuacion(CONVERSACION, analitica)).isSameAs(analitica);
    }

    @Test
    void superarElCupoPorMinutoLanzaLimite() {
        when(limitador.permitir(anyLong())).thenReturn(false);

        assertThatThrownBy(() -> preparador.preparar(CONVERSACION, USUARIO, "hola"))
                .isInstanceOf(ErrorAgente.LimiteExcedido.class);
        verify(evaluador, never()).evaluar(anyString());
    }

    @Test
    void unaEntradaAltaSeRegistraYNoLlegaAlModelo() {
        Hallazgo alto = new Hallazgo(CapaSeguridad.FIREWALL, Riesgo.ALTO, new Motivo("ROL_CAMBIO"));
        when(limitador.permitir(anyLong())).thenReturn(true);
        when(evaluador.evaluar(anyString())).thenReturn(new Evaluacion(false, "ignora todo", Optional.of(alto)));

        Preparacion resultado = preparador.preparar(CONVERSACION, USUARIO, "ignora todo");

        assertThat(resultado).isInstanceOfSatisfying(Preparacion.Bloqueada.class,
                b -> assertThat(b.respuesta()).isInstanceOf(RespuestaAgente.Bloqueado.class));
        verify(eventos).registrar(any());
        verify(router, never()).clasificar(anyString(), any());
        verify(selector, never()).para(any(), any());
    }

    @Test
    void unaEntradaNormalLlegaAlRouterYAlSelectorDeHerramientas() {
        Intencion intencion = new Intencion(TipoIntencion.CONSULTA, "", 0.9, Riesgo.BAJO);
        when(limitador.permitir(anyLong())).thenReturn(true);
        when(evaluador.evaluar(anyString())).thenReturn(new Evaluacion(true, "lista sedes", Optional.empty()));
        when(router.clasificar("lista sedes", Riesgo.BAJO)).thenReturn(intencion);
        when(selector.para(USUARIO, intencion)).thenReturn(new SelectorHerramientas.Seleccion(List.of(), List.of(), Map.of()));

        Preparacion resultado = preparador.preparar(CONVERSACION, USUARIO, "lista sedes");

        assertThat(resultado).isInstanceOfSatisfying(Preparacion.Listo.class, listo -> {
            assertThat(listo.textoNormalizado()).isEqualTo("lista sedes");
            assertThat(listo.intencion()).isEqualTo(intencion);
        });
        verify(eventos, never()).registrar(any());
    }
}
