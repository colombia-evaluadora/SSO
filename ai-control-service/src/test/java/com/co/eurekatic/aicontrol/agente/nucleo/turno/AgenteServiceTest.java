package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.TipoHerramienta;
import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.ArgumentosCanonicos;
import com.co.eurekatic.aicontrol.agente.comun.PropiedadesAgenteFixture;
import com.co.eurekatic.aicontrol.agente.comun.UsuarioAgente;
import com.co.eurekatic.aicontrol.agente.nucleo.AccionPropuesta;
import com.co.eurekatic.aicontrol.agente.nucleo.acciones.AccionesService;
import com.co.eurekatic.aicontrol.agente.nucleo.intencion.Intencion;
import com.co.eurekatic.aicontrol.agente.nucleo.intencion.TipoIntencion;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import com.co.eurekatic.aicontrol.agente.seguridad.Riesgo;
import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.ResultadoHerramienta.RequiereConfirmacion;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.time.LocalDateTime;
import com.co.eurekatic.aicontrol.agente.persistencia.analitica.ConsultaAnaliticaStore;

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
    private AgenteService servicio;

    @BeforeEach
    void setUp() {
        conversaciones = mock(ConversacionesService.class);
        preparador = mock(PreparadorTurno.class);
        registrador = mock(RegistradorTurno.class);
        bucle = mock(BucleAgente.class);
        acciones = mock(AccionesService.class);
        salida = mock(SalidaTurno.class);
        when(salida.revisar(any(), any(), anyLong())).thenAnswer(i -> i.getArgument(0));
        when(registrador.iniciar(any(), anyString())).thenReturn(new RegistradorTurno.Inicio(9L, List.of()));
        servicio = new AgenteService(conversaciones, preparador, registrador,
                new PromptTurno(new org.springframework.core.io.ClassPathResource("prompts/agente-sistema.st"),
                        PropiedadesAgenteFixture.propiedades().limites().textoMaxCaracteres()),
                bucle, acciones, salida,
                new PresentadorAnalitica(mock(ConsultaAnaliticaStore.class)), new TurnosEnCurso());
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
        verify(registrador).registrar(eq(CONVERSACION), any(RespuestaAgente.SinPermiso.class), eq(Consumo.NINGUNO));
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
        verify(registrador).registrar(eq(CONVERSACION), any(RespuestaAgente.Respuesta.class), any(Consumo.class));
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

    private static Preparacion.Listo listo(TipoIntencion tipo, List<HerramientaDef> herramientas) {
        return new Preparacion.Listo("texto", new Intencion(tipo, "", 0.9, Riesgo.BAJO), herramientas, List.of(), Map.of());
    }
}
