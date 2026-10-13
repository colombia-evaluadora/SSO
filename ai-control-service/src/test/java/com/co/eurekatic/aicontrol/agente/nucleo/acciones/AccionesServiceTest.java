package com.co.eurekatic.aicontrol.agente.nucleo.acciones;

import com.co.eurekatic.aicontrol.agente.catalogo.carga.CatalogoHerramientasLoader;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.CatalogoHerramientas;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.RutaQuery;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.TipoHerramienta;
import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.ArgumentosCanonicos;
import com.co.eurekatic.aicontrol.agente.comun.ErrorAgente;
import com.co.eurekatic.aicontrol.agente.comun.Huellas;
import com.co.eurekatic.aicontrol.agente.comun.UsuarioAgente;
import com.co.eurekatic.aicontrol.agente.nucleo.AccionPropuesta;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import com.co.eurekatic.aicontrol.agente.nucleo.turno.RegistradorTurno;
import com.co.eurekatic.aicontrol.agente.persistencia.accion.AccionPendienteStore;
import com.co.eurekatic.aicontrol.agente.persistencia.accion.AccionPendienteStore.AccionPendiente;
import com.co.eurekatic.aicontrol.agente.persistencia.accion.AccionPendienteStore.NuevaAccion;
import com.co.eurekatic.aicontrol.agente.persistencia.accion.EstadoAccion;
import com.co.eurekatic.aicontrol.client.QueryServiceClient;
import com.co.eurekatic.aicontrol.client.RespuestaQuery;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpMethod;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
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
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class AccionesServiceTest {

    private static final long USUARIO = 7L;
    private static final long HERRAMIENTA = 42L;
    private static final Instant AHORA = Instant.parse("2026-10-13T10:00:00Z");
    private static final String PAYLOAD = "{\"BODY.NOMBRE\": \"Ana\", \"BODY.SEDE\": 3}";

    /** Mismo instante que el reloj del servicio, para que los plazos sean deterministas. */
    private static final LocalDateTime AHORA_LOCAL = LocalDateTime.ofInstant(AHORA, ZoneOffset.UTC);

    private final UUID accionId = UUID.randomUUID();
    private final UUID conversacionId = UUID.randomUUID();
    private final UsuarioAgente usuario = new UsuarioAgente(USUARIO, Set.of("DOCENTE"), "token-usuario");

    private AccionPendienteStore store;
    private CatalogoHerramientasLoader catalogo;
    private QueryServiceClient queryService;
    private RegistradorTurno registrador;
    private AccionesService servicio;
    private HerramientaDef escritura;

    @BeforeEach
    void setUp() {
        store = mock(AccionPendienteStore.class);
        catalogo = mock(CatalogoHerramientasLoader.class);
        queryService = mock(QueryServiceClient.class);
        registrador = mock(RegistradorTurno.class);
        Clock reloj = Clock.fixed(AHORA, ZoneOffset.UTC);
        servicio = new AccionesService(store, catalogo, queryService, registrador, Duration.ofMinutes(10), reloj);
        escritura = new HerramientaDef(HERRAMIENTA, "crear_funcionario", TipoHerramienta.ESCRITURA, "Crear funcionario",
                List.of(), true, List.of(), 1, Optional.of("FUNCIONARIOS"),
                Optional.of(new RutaQuery(HttpMethod.POST, "/funcionarios", Map.of(), Map.of())), Set.of());
        when(catalogo.catalogo()).thenReturn(CatalogoHerramientas.con(List.of(escritura)));
    }

    @Test
    void proponerGuardaPayloadCanonicoConSuHuella() {
        ArgumentosCanonicos argumentos = new ArgumentosCanonicos(Map.of("BODY.SEDE", 3, "BODY.NOMBRE", "Ana"));
        when(store.crear(any(NuevaAccion.class))).thenReturn(fila(PAYLOAD, huella(PAYLOAD), AHORA_LOCAL.plusMinutes(10),
                EstadoAccion.PENDIENTE, null));

        AccionPropuesta propuesta = servicio.proponer(conversacionId, usuario, escritura, argumentos, "Crear a Ana");

        assertThat(propuesta.id()).isEqualTo(accionId);
        verify(store).crear(org.mockito.ArgumentMatchers.argThat(n ->
                n.payloadJson().equals("{\"BODY.NOMBRE\":\"Ana\",\"BODY.SEDE\":3}")
                        && n.payloadHash().equals(Huellas.sha256(n.payloadJson()))
                        && n.fkUsuario() == USUARIO));
    }

    @Test
    void unaEscrituraQueReemplazaLlevaSuAvisoEnElResumen() {
        HerramientaDef reemplaza = new HerramientaDef(HERRAMIENTA, "asignar_estudiantes_actividad",
                TipoHerramienta.ESCRITURA, "d", List.of(), true, List.of(), 1, Optional.of("PLANEADOR"),
                escritura.ruta(), Set.of(), Optional.of("Los que no incluyas saldrán de la actividad."));

        assertThat(AccionesService.resumenConAviso("Asignar 2 estudiantes", reemplaza))
                .isEqualTo("Asignar 2 estudiantes Atención: Los que no incluyas saldrán de la actividad.");
        assertThat(AccionesService.resumenConAviso("Crear a Ana", escritura)).isEqualTo("Crear a Ana");
    }

    @Test
    void confirmarEjecutaConElTokenDeQuienConfirmaYRegistraElResultado() {
        when(store.buscar(accionId, USUARIO)).thenReturn(Optional.of(pendiente(AHORA_LOCAL.plusMinutes(5), null)));
        when(store.transicionar(accionId, USUARIO, EstadoAccion.EJECUTADA, AccionPendienteStore.MARCA_EN_CURSO)).thenReturn(true);
        when(store.completar(eq(accionId), eq(USUARIO), eq(EstadoAccion.EJECUTADA), anyString())).thenReturn(true);
        when(queryService.invocar(eq(HttpMethod.POST), eq("/funcionarios"), any(), any(), eq("token-usuario")))
                .thenReturn(new RespuestaQuery.Exito(List.of()));

        RespuestaAgente respuesta = servicio.confirmar(accionId, usuario);

        assertThat(respuesta).isInstanceOfSatisfying(RespuestaAgente.Respuesta.class,
                r -> assertThat(r.texto()).startsWith("Hecho:"));
        verify(queryService, times(1)).invocar(any(), any(), any(), any(), anyString());
        verify(registrador).registrar(eq(conversacionId), any(), any());
    }

    @Test
    void unaHuellaAlteradaSeRechazaSinEjecutar() {
        String alterado = "{\"BODY.NOMBRE\": \"Otra\", \"BODY.SEDE\": 3}";
        when(store.buscar(accionId, USUARIO)).thenReturn(Optional.of(fila(alterado, huella(PAYLOAD),
                AHORA_LOCAL.plusMinutes(5), EstadoAccion.PENDIENTE, null)));

        assertThatThrownBy(() -> servicio.confirmar(accionId, usuario)).isInstanceOf(ErrorAgente.AccionAlterada.class);

        verify(store, never()).transicionar(any(), anyLong(), eq(EstadoAccion.EJECUTADA), anyString());
        verify(queryService, never()).invocar(any(), any(), any(), any(), anyString());
    }

    @Test
    void unaAccionVencidaSeMarcaComoExpiradaYNoSeEjecuta() {
        when(store.buscar(accionId, USUARIO)).thenReturn(Optional.of(pendiente(AHORA_LOCAL.minusMinutes(1), null)));

        assertThatThrownBy(() -> servicio.confirmar(accionId, usuario)).isInstanceOf(ErrorAgente.AccionExpirada.class);

        verify(store).marcarExpiradas();
        verify(queryService, never()).invocar(any(), any(), any(), any(), anyString());
    }

    @Test
    void unaAccionAjenaNoExiste() {
        when(store.buscar(accionId, USUARIO)).thenReturn(Optional.empty());

        assertThatThrownBy(() -> servicio.confirmar(accionId, usuario)).isInstanceOf(ErrorAgente.AccionNoEncontrada.class);
    }

    @Test
    void unaSegundaConfirmacionNoEjecutaOtraVez() {
        when(store.buscar(accionId, USUARIO)).thenReturn(Optional.of(pendiente(AHORA_LOCAL.plusMinutes(5), null)));
        when(store.transicionar(accionId, USUARIO, EstadoAccion.EJECUTADA, AccionPendienteStore.MARCA_EN_CURSO))
                .thenReturn(true, false);
        when(store.completar(any(), anyLong(), any(), anyString())).thenReturn(true);
        when(queryService.invocar(any(), any(), any(), any(), anyString())).thenReturn(new RespuestaQuery.Exito(List.of()));

        servicio.confirmar(accionId, usuario);
        assertThatThrownBy(() -> servicio.confirmar(accionId, usuario)).isInstanceOf(ErrorAgente.AccionNoPendiente.class);

        verify(queryService, times(1)).invocar(any(), any(), any(), any(), anyString());
    }

    @Test
    void unRechazoDelServicioSeTraduceYQuedaFallida() {
        when(store.buscar(accionId, USUARIO)).thenReturn(Optional.of(pendiente(AHORA_LOCAL.plusMinutes(5), null)));
        when(store.transicionar(accionId, USUARIO, EstadoAccion.EJECUTADA, AccionPendienteStore.MARCA_EN_CURSO)).thenReturn(true);
        when(store.completar(eq(accionId), eq(USUARIO), eq(EstadoAccion.FALLIDA), anyString())).thenReturn(true);
        when(queryService.invocar(any(), any(), any(), any(), anyString()))
                .thenReturn(new RespuestaQuery.ErrorCliente(403, "sin permiso"));

        RespuestaAgente respuesta = servicio.confirmar(accionId, usuario);

        assertThat(respuesta.texto()).startsWith("No tienes permiso");
        verify(store).completar(eq(accionId), eq(USUARIO), eq(EstadoAccion.FALLIDA), anyString());
    }

    @Test
    void cancelarDescartaLaAccionSinEjecutarla() {
        when(store.buscar(accionId, USUARIO)).thenReturn(Optional.of(pendiente(AHORA_LOCAL.plusMinutes(5), null)));
        when(store.transicionar(accionId, USUARIO, EstadoAccion.DESCARTADA, null)).thenReturn(true);

        RespuestaAgente respuesta = servicio.cancelar(accionId, usuario);

        assertThat(respuesta.texto()).startsWith("Acción cancelada");
        verify(queryService, never()).invocar(any(), any(), any(), any(), anyString());
    }

    @Test
    void unaHerramientaRetiradaDelCatalogoQuedaFallidaSinLlamar() {
        when(store.buscar(accionId, USUARIO)).thenReturn(Optional.of(pendiente(AHORA_LOCAL.plusMinutes(5), null)));
        when(store.transicionar(accionId, USUARIO, EstadoAccion.EJECUTADA, AccionPendienteStore.MARCA_EN_CURSO)).thenReturn(true);
        when(store.completar(eq(accionId), eq(USUARIO), eq(EstadoAccion.FALLIDA), anyString())).thenReturn(true);
        when(catalogo.catalogo()).thenReturn(CatalogoHerramientas.vacio());

        RespuestaAgente respuesta = servicio.confirmar(accionId, usuario);

        assertThat(respuesta.texto()).contains("ya no está disponible");
        verify(queryService, never()).invocar(any(), any(), any(), any(), anyString());
    }

    private static String huella(String payload) {
        return Huellas.sha256(com.co.eurekatic.aicontrol.agente.nucleo.acciones.CanonicoPayload.canonico(payload));
    }

    private AccionPendiente pendiente(LocalDateTime expira, String resultado) {
        return fila(PAYLOAD, huella(PAYLOAD), expira, EstadoAccion.PENDIENTE, resultado);
    }

    private AccionPendiente fila(String payload, String hash, LocalDateTime expira, EstadoAccion estado, String resultado) {
        return new AccionPendiente(accionId, conversacionId, USUARIO, HERRAMIENTA, payload, hash, "Crear a Ana",
                estado, expira, null, resultado);
    }
}
