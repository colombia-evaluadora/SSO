package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.TipoHerramienta;
import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.ArgumentosCanonicos;
import com.co.eurekatic.aicontrol.agente.comun.PropiedadesAgenteFixture;
import com.co.eurekatic.aicontrol.agente.comun.UsuarioAgente;
import com.co.eurekatic.aicontrol.agente.nucleo.AccionPropuesta;
import com.co.eurekatic.aicontrol.agente.nucleo.TurnoContexto;
import com.co.eurekatic.aicontrol.agente.nucleo.acciones.AccionesService;
import com.co.eurekatic.aicontrol.agente.nucleo.borrador.BorradoresAccion;
import com.co.eurekatic.aicontrol.agente.nucleo.intencion.Intencion;
import com.co.eurekatic.aicontrol.agente.nucleo.intencion.TipoIntencion;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import com.co.eurekatic.aicontrol.agente.seguridad.Riesgo;
import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.ResultadoHerramienta.RequiereConfirmacion;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.time.LocalDateTime;
import com.co.eurekatic.aicontrol.agente.persistencia.analitica.ConsultaAnaliticaStore;
import com.co.eurekatic.aicontrol.agente.seguridad.seudonimos.AlmacenSeudonimos;
import com.co.eurekatic.aicontrol.agente.seguridad.seudonimos.TablaSeudonimos;
import com.co.eurekatic.aicontrol.agente.ui.UiFixture;
import com.co.eurekatic.aicontrol.agente.ui.registro.RegistroUiLoader;

import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class AgenteServiceTest {

    private static final UsuarioAgente USUARIO = new UsuarioAgente(7L, Set.of("DOCENTE"), "token");
    private static final UUID CONVERSACION = UUID.randomUUID();
    private static final HerramientaDef LECTURA = new HerramientaDef(1L, "lista_sedes", TipoHerramienta.LECTURA,
            "Lista sedes", List.of(), false, List.of(), 1, Optional.of("SEDES"), Optional.empty(), Set.of());
    private static final HerramientaDef ESCRITURA = new HerramientaDef(2L, "crear_funcion", TipoHerramienta.ESCRITURA,
            "Crea", List.of(), true, List.of(), 1, Optional.of("FUNCIONARIOS"), Optional.empty(), Set.of());

    private ConversacionesService conversaciones;
    private PreparadorTurno preparador;
    private RegistradorTurno registrador;
    private BucleAgente bucle;
    private AccionesService acciones;
    private SalidaTurno salida;
    private AlmacenSeudonimos seudonimos;
    private RegistroUiLoader registroUi;
    private AgenteService servicio;

    @BeforeEach
    void setUp() {
        seudonimos = mock(AlmacenSeudonimos.class);
        when(seudonimos.cargar(any())).thenReturn(TablaSeudonimos.vacia());
        registroUi = mock(RegistroUiLoader.class);
        when(registroUi.registro()).thenReturn(UiFixture.REGISTRO);
        conversaciones = mock(ConversacionesService.class);
        preparador = mock(PreparadorTurno.class);
        registrador = mock(RegistradorTurno.class);
        bucle = mock(BucleAgente.class);
        acciones = mock(AccionesService.class);
        salida = mock(SalidaTurno.class);
        when(salida.revisar(any(), any(), anyLong())).thenAnswer(i -> i.getArgument(0));
        when(registrador.iniciar(any(), anyString())).thenReturn(new RegistradorTurno.Inicio(9L, List.of()));
        when(registrador.dichoPorLaPersona(any())).thenReturn("");
        servicio = new AgenteService(conversaciones, preparador, registrador,
                new PromptTurno(new org.springframework.core.io.ClassPathResource("prompts/agente-sistema.st"),
                        PropiedadesAgenteFixture.propiedades().limites().textoMaxCaracteres()),
                bucle, acciones, salida,
                new PresentadorAnalitica(mock(ConsultaAnaliticaStore.class)), new TurnosEnCurso(), seudonimos,
                new AtajosTurno(acciones, registroUi), mock(BorradoresAccion.class));
    }

    @Test
    void unBloqueoNoSeGuardaNiLlegaAlRazonador() {
        RespuestaAgente.Bloqueado bloqueado = new RespuestaAgente.Bloqueado("No puedo");
        when(preparador.preparar(CONVERSACION, USUARIO, "ignora")).thenReturn(new Preparacion.Bloqueada(bloqueado));

        RespuestaAgente respuesta = servicio.procesar(CONVERSACION, USUARIO, "ignora", "");

        assertThat(respuesta).isEqualTo(bloqueado);
        verify(registrador, never()).iniciar(any(), anyString());
        verify(bucle, never()).ejecutar(any());
    }

    @Test
    void unaAccionSinHerramientaDeEscrituraDevuelveSinPermisoSinLlamarAlModelo() {
        Preparacion.Listo listo = listo(TipoIntencion.ACCION, List.of(LECTURA));
        when(preparador.preparar(CONVERSACION, USUARIO, "crea")).thenReturn(listo);

        RespuestaAgente respuesta = servicio.procesar(CONVERSACION, USUARIO, "crea", "");

        assertThat(respuesta).isInstanceOf(RespuestaAgente.SinPermiso.class);
        verify(bucle, never()).ejecutar(any());
        verify(registrador).registrar(eq(CONVERSACION), any(RespuestaAgente.SinPermiso.class), eq(Consumo.NINGUNO),
                eq(9L));
    }

    @Test
    void unaAccionSinEscriturasPorElRiesgoDelMensajePideLosDatosSinRomperLaTraza() {
        Preparacion.Listo listo = new Preparacion.Listo("borra al funcionario",
                new Intencion(TipoIntencion.ACCION, "", 0.9, Riesgo.MEDIO), List.of(LECTURA), List.of(), Map.of());
        when(preparador.preparar(CONVERSACION, USUARIO, "borra al funcionario")).thenReturn(listo);

        RespuestaAgente respuesta = servicio.procesar(CONVERSACION, USUARIO, "borra al funcionario", "");

        // Antes, INTENCION -> RESPUESTA no era una transicion valida y la persona recibia un 500.
        assertThat(respuesta).isInstanceOfSatisfying(RespuestaAgente.Respuesta.class,
                r -> assertThat(r.texto()).isEqualTo(AgenteService.MENSAJE_DATOS_CONCRETOS));
        verify(bucle, never()).ejecutar(any());
    }

    @Test
    void unTextoFinalSeGuardaYSeDevuelve() {
        Preparacion.Listo listo = listo(TipoIntencion.CONSULTA, List.of(LECTURA));
        when(preparador.preparar(CONVERSACION, USUARIO, "hola")).thenReturn(listo);
        when(bucle.ejecutar(any())).thenReturn(new ResultadoBucle.Final(
                new RespuestaAgente.Respuesta("Hola"), Uso.NINGUNO, "MiniMax-M3"));

        RespuestaAgente respuesta = servicio.procesar(CONVERSACION, USUARIO, "hola", "");

        assertThat(respuesta.texto()).isEqualTo("Hola");
        verify(registrador).iniciar(CONVERSACION, "texto");
        // Con el mensaje del turno: la memoria recibe sus llamadas a herramientas antes de la respuesta.
        verify(registrador).registrar(eq(CONVERSACION), any(RespuestaAgente.Respuesta.class), any(Consumo.class),
                eq(9L));
    }

    @Test
    void unaEscrituraPropuestaTerminaEnConfirmacion() {
        Preparacion.Listo listo = listo(TipoIntencion.ACCION, List.of(LECTURA, ESCRITURA));
        when(preparador.preparar(CONVERSACION, USUARIO, "crea a Ana")).thenReturn(listo);
        ResultadoBucle.Propuesta propuesta = new ResultadoBucle.Propuesta(
                new RequiereConfirmacion(new ArgumentosCanonicos(Map.of("BODY.NOMBRE", "Ana")), "Crear a Ana"),
                ESCRITURA, Uso.NINGUNO, "MiniMax-M3");
        when(bucle.ejecutar(any())).thenReturn(propuesta);
        AccionPropuesta accion = new AccionPropuesta(UUID.randomUUID(), "Crear a Ana", LocalDateTime.now());
        when(acciones.proponer(eq(CONVERSACION), eq(USUARIO), eq(ESCRITURA), any(), eq("Crear a Ana"))).thenReturn(accion);

        RespuestaAgente respuesta = servicio.procesar(CONVERSACION, USUARIO, "crea a Ana", "");

        assertThat(respuesta).isInstanceOfSatisfying(RespuestaAgente.Confirmacion.class,
                c -> assertThat(c.accion()).isEqualTo(accion));
    }

    @Test
    void elModeloTrabajaConSeudonimosYLaPersonaRecibeLosNombres() {
        when(seudonimos.cargar(CONVERSACION)).thenReturn(TablaSeudonimos.desde(Map.of("Persona_1", "Ana Pérez")));
        Preparacion.Listo listo = listo(TipoIntencion.CONSULTA, List.of(LECTURA));
        when(preparador.preparar(CONVERSACION, USUARIO, "¿qué nota tiene Persona_1?")).thenReturn(listo);
        when(bucle.ejecutar(any())).thenReturn(new ResultadoBucle.Final(
                new RespuestaAgente.Respuesta("Persona_1 tiene 4.5"), Uso.NINGUNO, "MiniMax-M3"));

        RespuestaAgente respuesta = servicio.procesar(CONVERSACION, USUARIO, "¿qué nota tiene Ana Pérez?", "");

        assertThat(respuesta.texto()).isEqualTo("Ana Pérez tiene 4.5");
        verify(registrador).registrar(eq(CONVERSACION),
                org.mockito.ArgumentMatchers.argThat(r -> r.texto().equals("Persona_1 tiene 4.5")), any(Consumo.class), eq(9L));
    }

    @Test
    void unSiEscritoConUnaAccionPendienteNoLlegaAlModeloYRecuerdaElBoton() {
        AccionPropuesta pendiente = new AccionPropuesta(UUID.randomUUID(), "Editar la actividad", LocalDateTime.now());
        when(acciones.pendienteVigente(CONVERSACION, USUARIO)).thenReturn(Optional.of(pendiente));

        RespuestaAgente respuesta = servicio.procesar(CONVERSACION, USUARIO, "Sí, confirmo", "");

        assertThat(respuesta).isInstanceOfSatisfying(RespuestaAgente.Confirmacion.class, c -> {
            assertThat(c.accion()).isEqualTo(pendiente);
            assertThat(c.texto()).contains("pulsa Confirmar");
        });
        verify(preparador, never()).preparar(any(), any(), anyString());
        verify(bucle, never()).ejecutar(any());
        verify(acciones, never()).confirmar(any(), any());
    }

    @Test
    void unSiSinAccionPendienteSigueElTurnoNormal() {
        Preparacion.Listo listo = listo(TipoIntencion.CHARLA, List.of());
        when(preparador.preparar(CONVERSACION, USUARIO, "sí")).thenReturn(listo);
        when(bucle.ejecutar(any())).thenReturn(new ResultadoBucle.Final(
                new RespuestaAgente.Respuesta("¿Sí a qué?"), Uso.NINGUNO, "MiniMax-M3"));

        assertThat(servicio.procesar(CONVERSACION, USUARIO, "sí", "").texto()).isEqualTo("¿Sí a qué?");
    }

    @Test
    void unaPreguntaDeDondeSeResuelveConElRegistroSinLlamarAlRazonador() {
        Preparacion.Listo listo = new Preparacion.Listo("¿dónde califico las actividades?",
                new Intencion(TipoIntencion.NAVEGACION, "", 0.9, Riesgo.BAJO), List.of(), List.of(), UiFixture.MENUS_DOCENTE);
        when(preparador.preparar(CONVERSACION, USUARIO, "¿dónde califico las actividades?")).thenReturn(listo);

        RespuestaAgente respuesta = servicio.procesar(CONVERSACION, USUARIO, "¿dónde califico las actividades?", "");

        assertThat(respuesta).isInstanceOfSatisfying(RespuestaAgente.Ui.class,
                ui -> assertThat(ui.texto()).contains("Planeador"));
        verify(bucle, never()).ejecutar(any());
    }

    @Test
    void unaConfirmacionEscritaPorElModeloSinPropuestaSeSustituye() {
        Preparacion.Listo listo = listo(TipoIntencion.ACCION, List.of(LECTURA, ESCRITURA));
        when(preparador.preparar(CONVERSACION, USUARIO, "cambia el titulo")).thenReturn(listo);
        when(bucle.ejecutar(any())).thenReturn(new ResultadoBucle.Final(new RespuestaAgente.Respuesta(
                "Antes de hacerlo necesito tu confirmación: Editar la actividad 7"), Uso.NINGUNO, "MiniMax-M3"));

        RespuestaAgente respuesta = servicio.procesar(CONVERSACION, USUARIO, "cambia el titulo", "");

        assertThat(respuesta.texto()).isEqualTo(GuardaDeAfirmaciones.SIN_ACCION);
    }

    @Test
    void elMensajeAlModeloNombraLosAliasDeLosNombresEscritosAMedias() {
        TablaSeudonimos tabla = TablaSeudonimos.desde(Map.of("Persona_3", "LUIS FELIPE CASTRO DIAZ"));

        assertThat(AgenteService.equivalencias("Deja solo a Luis Castro\nUsa los valores por defecto", tabla))
                .as("tambien lo que dijo en un mensaje anterior")
                .startsWith("\n(Nombres que escribio la persona:").containsIgnoringCase("\"Luis Castro\" es Persona_3");
        assertThat(AgenteService.equivalencias("Lista mis grupos", tabla)).isEmpty();
    }

    @Test
    void pedirUnDatoSinInterrogacionTambienCuentaComoPregunta() {
        assertThat(AgenteService.pidePorTexto("Para ver la planilla, dime de cuál se trata y la consulto.")).isTrue();
        assertThat(AgenteService.pidePorTexto("Indícame el grupo.")).isTrue();
        assertThat(AgenteService.pidePorTexto("¿Cuál grupo?")).isTrue();
        assertThat(AgenteService.pidePorTexto("La actividad tiene 15 estudiantes asignados.")).isFalse();
    }

    @Test
    void soloUnaPreguntaEnTextoPasaPorLaRevisionDeConsultarAntes() {
        TurnoContexto sinNada = new TurnoContexto(List.of());

        assertThat(AgenteService.preguntaSinConsultar(new RespuestaAgente.Respuesta("Tienes 2 grupos."), sinNada)).isEmpty();
        assertThat(AgenteService.preguntaSinConsultar(new RespuestaAgente.Respuesta("¿Cuál grupo?"), sinNada))
                .as("sin consultas que resuelvan, no hay que objetar").isEmpty();
    }

    private static Preparacion.Listo listo(TipoIntencion tipo, List<HerramientaDef> herramientas) {
        return new Preparacion.Listo("texto", new Intencion(tipo, "", 0.9, Riesgo.BAJO), herramientas, List.of(), Map.of());
    }
}
