package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import com.co.eurekatic.aicontrol.agente.comun.UsuarioAgente;
import com.co.eurekatic.aicontrol.agente.nucleo.AccionPropuesta;
import com.co.eurekatic.aicontrol.agente.nucleo.TurnoContexto;
import com.co.eurekatic.aicontrol.agente.nucleo.acciones.AccionesService;
import com.co.eurekatic.aicontrol.agente.nucleo.intencion.Intencion;
import com.co.eurekatic.aicontrol.agente.nucleo.intencion.TipoIntencion;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import com.co.eurekatic.aicontrol.agente.ui.contexto.LectorContextoUi;
import org.springframework.stereotype.Service;

import java.util.UUID;

/**
 * Procesa un mensaje del usuario de principio a fin: conversacion, preparacion (seguridad, intencion,
 * herramientas), bucle del razonador, escrituras propuestas y salida segura. Cada paso lo hace un
 * colaborador; este servicio solo decide el orden y el cierre.
 */
@Service
public class AgenteService {

    static final String MENSAJE_SIN_PERMISO = "No tienes permiso para hacer esa acción desde el asistente.";
    static final String TEXTO_CONFIRMACION = "Antes de hacerlo necesito tu confirmación: %s";
    private static final long NANOS_POR_MILISEGUNDO = 1_000_000L;

    private final ConversacionesService conversaciones;
    private final PreparadorTurno preparador;
    private final RegistradorTurno registrador;
    private final PromptTurno prompts;
    private final BucleAgente bucle;
    private final AccionesService acciones;
    private final SalidaTurno salida;
    private final PresentadorAnalitica analitica;
    private final TurnosEnCurso enCurso;

    public AgenteService(ConversacionesService conversaciones, PreparadorTurno preparador, RegistradorTurno registrador,
                         PromptTurno prompts, BucleAgente bucle, AccionesService acciones, SalidaTurno salida,
                         PresentadorAnalitica analitica, TurnosEnCurso enCurso) {
        this.conversaciones = conversaciones;
        this.preparador = preparador;
        this.registrador = registrador;
        this.prompts = prompts;
        this.bucle = bucle;
        this.acciones = acciones;
        this.salida = salida;
        this.analitica = analitica;
        this.enCurso = enCurso;
    }

    /**
     * @param contextoUiJson contexto de la pantalla en JSON; cadena vacia si no hay. Es un dato, no una instruccion
     * @throws com.co.eurekatic.aicontrol.agente.comun.ErrorAgente si la conversacion no es propia o no admite mensajes
     */
    public RespuestaAgente procesar(UUID conversacionId, UsuarioAgente usuario, String texto, String contextoUiJson) {
        return procesar(conversacionId, usuario, texto, contextoUiJson, ObservadorTurno.NINGUNO);
    }

    /**
     * Igual, avisando de cada paso al observador (streaming).
     *
     * @throws com.co.eurekatic.aicontrol.agente.comun.ErrorAgente.TurnoEnCurso si el usuario ya tiene un turno en marcha
     */
    public RespuestaAgente procesar(UUID conversacionId, UsuarioAgente usuario, String texto, String contextoUiJson,
                                    ObservadorTurno observador) {
        try (TurnosEnCurso.Turno _ = enCurso.abrir(usuario.userId())) {
            return procesarReservado(conversacionId, usuario, texto, contextoUiJson, observador);
        }
    }

    private RespuestaAgente procesarReservado(UUID conversacionId, UsuarioAgente usuario, String texto,
                                              String contextoUiJson, ObservadorTurno observador) {
        long inicio = System.nanoTime();
        TrazaTurno traza = TrazaTurno.iniciar(conversacionId, observador);
        conversaciones.activa(conversacionId, usuario);
        traza.pasar(EstadoTurno.VALIDADO);
        Preparacion preparacion = preparador.preparar(conversacionId, usuario, texto);
        return switch (preparacion) {
            case Preparacion.Bloqueada bloqueada -> {
                traza.pasar(EstadoTurno.BLOQUEADO);
                traza.cerrar();
                yield bloqueada.respuesta();
            }
            case Preparacion.Listo listo -> turno(conversacionId, usuario, listo, contextoUiJson, traza, inicio);
        };
    }

    private RespuestaAgente turno(UUID conversacionId, UsuarioAgente usuario, Preparacion.Listo listo,
                                  String contextoUiJson, TrazaTurno traza, long inicio) {
        traza.pasar(EstadoTurno.INTENCION);
        RegistradorTurno.Inicio arranque = registrador.iniciar(conversacionId, listo.textoNormalizado());
        if (sinHerramientaDeEscritura(listo.intencion(), listo)) {
            return cerrar(conversacionId, usuario, new RespuestaAgente.SinPermiso(MENSAJE_SIN_PERMISO),
                    Consumo.NINGUNO, traza);
        }
        traza.pasar(EstadoTurno.PERMISO_OK);
        traza.pasar(EstadoTurno.RECOLECTANDO);
        TurnoContexto contexto = new TurnoContexto(listo.herramientas(), LectorContextoUi.leer(contextoUiJson),
                listo.menus());
        ResultadoBucle resultado = bucle.ejecutar(new BucleAgente.Entrada(
                usuario,
                conversacionId,
                arranque.mensajeId(),
                listo.textoNormalizado(),
                prompts.mensajes(arranque.historial(), listo.textoNormalizado(), contextoUiJson),
                listo.callbacks(),
                contexto));
        Consumo consumo = new Consumo(resultado.uso(), resultado.modelo(), milisegundosDesde(inicio));
        RespuestaAgente respuesta = switch (resultado) {
            case ResultadoBucle.Final fin -> analitica.presentar(fin.respuesta(), contexto, arranque.mensajeId());
            case ResultadoBucle.Propuesta propuesta -> confirmacion(conversacionId, usuario, propuesta);
        };
        return cerrar(conversacionId, usuario, respuesta, consumo, traza);
    }

    /** Accion sin ninguna herramienta de escritura disponible: no hay nada que proponer. */
    private static boolean sinHerramientaDeEscritura(Intencion intencion, Preparacion.Listo listo) {
        return intencion.tipo() == TipoIntencion.ACCION
                && listo.herramientas().stream().noneMatch(h -> h.tipo().escribe());
    }

    private RespuestaAgente confirmacion(UUID conversacionId, UsuarioAgente usuario, ResultadoBucle.Propuesta propuesta) {
        AccionPropuesta accion = acciones.proponer(conversacionId, usuario, propuesta.herramienta(),
                propuesta.confirmacion().argumentos(), propuesta.confirmacion().resumen());
        return new RespuestaAgente.Confirmacion(TEXTO_CONFIRMACION.formatted(accion.resumen()), accion);
    }

    /** Pasa la respuesta por la salida segura, la guarda y cierra el recorrido. */
    private RespuestaAgente cerrar(UUID conversacionId, UsuarioAgente usuario, RespuestaAgente respuesta,
                                   Consumo consumo, TrazaTurno traza) {
        RespuestaAgente revisada = salida.revisar(respuesta, conversacionId, usuario.userId());
        traza.pasar(EstadoTurno.de(revisada.tipo()));
        registrador.registrar(conversacionId, revisada, consumo);
        traza.cerrar();
        return revisada;
    }

    private static long milisegundosDesde(long inicioNanos) {
        return (System.nanoTime() - inicioNanos) / NANOS_POR_MILISEGUNDO;
    }
}
