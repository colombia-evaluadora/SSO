package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import com.co.eurekatic.aicontrol.agente.comun.ErrorAgente;
import com.co.eurekatic.aicontrol.agente.comun.UsuarioAgente;
import com.co.eurekatic.aicontrol.agente.memoria.NotaDeMemoria;
import com.co.eurekatic.aicontrol.agente.nucleo.AccionPropuesta;
import com.co.eurekatic.aicontrol.agente.nucleo.TurnoContexto;
import com.co.eurekatic.aicontrol.agente.nucleo.acciones.AccionesService;
import com.co.eurekatic.aicontrol.agente.nucleo.borrador.BorradorAccion;
import com.co.eurekatic.aicontrol.agente.nucleo.borrador.BorradoresAccion;
import com.co.eurekatic.aicontrol.agente.nucleo.control.PedirDatosFaltantesHerramienta;
import com.co.eurekatic.aicontrol.agente.nucleo.intencion.Intencion;
import com.co.eurekatic.aicontrol.agente.nucleo.intencion.TipoIntencion;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import com.co.eurekatic.aicontrol.agente.seguridad.NormalizadorTexto;
import com.co.eurekatic.aicontrol.agente.seguridad.seudonimos.AlmacenSeudonimos;
import com.co.eurekatic.aicontrol.agente.seguridad.seudonimos.TablaSeudonimos;
import com.co.eurekatic.aicontrol.agente.ui.contexto.LectorContextoUi;
import org.springframework.stereotype.Service;

import java.util.Optional;
import java.util.UUID;
import java.util.regex.Pattern;
import java.util.stream.Collectors;

/**
 * Procesa un mensaje del usuario de principio a fin: conversacion, preparacion (seguridad, intencion,
 * herramientas), bucle del razonador, escrituras propuestas y salida segura. Cada paso lo hace un
 * colaborador; este servicio solo decide el orden y el cierre.
 */
@Service
public class AgenteService {

    static final String MENSAJE_SIN_PERMISO = "No tienes permiso para hacer esa acción desde el asistente.";
    static final String MENSAJE_CANCELADO = "Cancelaste la petición.";
    static final String MENSAJE_DATOS_CONCRETOS = "Para preparar esa acción dime los datos concretos que quieres usar "
            + "(por ejemplo el valor del campo que falta) y la preparo.";
    static final String TEXTO_CONFIRMACION = NotaDeMemoria.PREFIJO_CONFIRMACION + "%s";
    static final String TEXTO_USA_BOTON = "Para hacerlo, pulsa Confirmar en la acción pendiente: %s. "
            + "Escribirlo en el chat no la ejecuta.";
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
    private final AlmacenSeudonimos almacenSeudonimos;
    private final AtajosTurno atajos;
    private final BorradoresAccion borradores;

    public AgenteService(ConversacionesService conversaciones, PreparadorTurno preparador, RegistradorTurno registrador,
                         PromptTurno prompts, BucleAgente bucle, AccionesService acciones, SalidaTurno salida,
                         PresentadorAnalitica analitica, TurnosEnCurso enCurso, AlmacenSeudonimos almacenSeudonimos,
                         AtajosTurno atajos, BorradoresAccion borradores) {
        this.conversaciones = conversaciones;
        this.preparador = preparador;
        this.registrador = registrador;
        this.prompts = prompts;
        this.bucle = bucle;
        this.acciones = acciones;
        this.salida = salida;
        this.analitica = analitica;
        this.enCurso = enCurso;
        this.almacenSeudonimos = almacenSeudonimos;
        this.atajos = atajos;
        this.borradores = borradores;
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
        try (TurnosEnCurso.Turno reserva = enCurso.abrir(usuario.userId(), conversacionId)) {
            return procesarReservado(conversacionId, usuario, texto, contextoUiJson, observador, reserva.senal());
        }
    }

    /**
     * Corta el turno en curso de la conversacion y libera la reserva del usuario.
     *
     * @return false si no habia un turno en marcha en esa conversacion
     * @throws com.co.eurekatic.aicontrol.agente.comun.ErrorAgente.ConversacionNoEncontrada si no es propia
     */
    public boolean cancelar(UUID conversacionId, UsuarioAgente usuario) {
        conversaciones.verificar(conversacionId, usuario);
        return enCurso.cancelar(usuario.userId(), conversacionId);
    }

    private RespuestaAgente procesarReservado(UUID conversacionId, UsuarioAgente usuario, String texto,
                                              String contextoUiJson, ObservadorTurno observador,
                                              SenalCancelacion senal) {
        long inicio = System.nanoTime();
        TrazaTurno traza = TrazaTurno.iniciar(conversacionId, observador);
        conversaciones.activa(conversacionId, usuario);
        traza.pasar(EstadoTurno.VALIDADO);
        // Desde aqui todo lo que va al proveedor del modelo lleva los nombres conocidos como seudonimos.
        TablaSeudonimos seudonimos = almacenSeudonimos.cargar(conversacionId);
        Optional<AccionPropuesta> pendiente = atajos.confirmacionEscrita(conversacionId, usuario, texto);
        if (pendiente.isPresent()) {
            return recordarConfirmacion(conversacionId, usuario, seudonimos.ocultar(texto), pendiente.get(),
                    seudonimos, traza);
        }
        Preparacion preparacion = preparador.preparar(conversacionId, usuario, seudonimos.ocultar(texto));
        return switch (preparacion) {
            case Preparacion.Bloqueada bloqueada -> {
                traza.pasar(EstadoTurno.BLOQUEADO);
                traza.cerrar();
                yield bloqueada.respuesta();
            }
            case Preparacion.Listo listo ->
                    turno(conversacionId, usuario, listo, contextoUiJson, seudonimos, traza, inicio, observador, senal);
        };
    }

    private RespuestaAgente turno(UUID conversacionId, UsuarioAgente usuario, Preparacion.Listo listo,
                                  String contextoUiJson, TablaSeudonimos seudonimos, TrazaTurno traza, long inicio,
                                  ObservadorTurno observador, SenalCancelacion senal) {
        traza.pasar(EstadoTurno.INTENCION);
        traza.anotar(listo.intencion());
        RegistradorTurno.Inicio arranque = registrador.iniciar(conversacionId, listo.textoNormalizado());
        if (sinHerramientaDeEscritura(listo.intencion(), listo)) {
            // Si lo que apaga las escrituras es el riesgo del mensaje, no es falta de permiso: decirlo asi confunde.
            boolean sinPermiso = listo.intencion().riesgo().permiteEscritura();
            if (!sinPermiso) {
                // El permiso esta; es el riesgo: la traza llega a RESPUESTA por el camino normal.
                traza.pasar(EstadoTurno.PERMISO_OK);
                traza.pasar(EstadoTurno.RECOLECTANDO);
            }
            RespuestaAgente sinEscrituras = sinPermiso
                    ? new RespuestaAgente.SinPermiso(MENSAJE_SIN_PERMISO)
                    : new RespuestaAgente.Respuesta(MENSAJE_DATOS_CONCRETOS);
            return cerrar(conversacionId, usuario, sinEscrituras, Consumo.NINGUNO, seudonimos, traza,
                    arranque.mensajeId());
        }
        traza.pasar(EstadoTurno.PERMISO_OK);
        traza.pasar(EstadoTurno.RECOLECTANDO);
        Optional<RespuestaAgente.Ui> pantalla = atajos.pantalla(listo.intencion(), listo.textoNormalizado(), listo.menus());
        if (pantalla.isPresent()) {
            return cerrar(conversacionId, usuario, pantalla.get(), Consumo.NINGUNO, seudonimos, traza,
                    arranque.mensajeId());
        }
        TurnoContexto contexto = new TurnoContexto(listo.herramientas(), LectorContextoUi.leer(contextoUiJson),
                listo.menus(), seudonimos);
        Optional<BorradorAccion> borrador = borradores.cargar(conversacionId);
        String dichoPorLaPersona = registrador.dichoPorLaPersona(conversacionId);
        ResultadoBucle resultado;
        try {
            resultado = bucle.ejecutar(new BucleAgente.Entrada(
                    usuario,
                    conversacionId,
                    arranque.mensajeId(),
                    dichoPorLaPersona,
                    prompts.mensajes(arranque.historial(),
                            listo.textoNormalizado() + equivalencias(dichoPorLaPersona, seudonimos)
                                    + notaDeBorrador(borrador, listo),
                            contextoUiJson),
                    listo.callbacks(),
                    contexto,
                    texto -> GuardaDeAfirmaciones.objecion(texto)
                            .or(() -> preguntaSinConsultar(texto, contexto)),
                    observador,
                    senal));
        } catch (ErrorAgente.TurnoCancelado cancelado) {
            // El historial queda con su respuesta: sin ella el siguiente turno ve dos mensajes seguidos de la persona.
            return cerrar(conversacionId, usuario, new RespuestaAgente.Respuesta(MENSAJE_CANCELADO), Consumo.NINGUNO,
                    seudonimos, traza, arranque.mensajeId());
        }
        contexto.borrador().ifPresent(intento -> borradores.guardar(conversacionId, borrador, intento));
        Consumo consumo = new Consumo(resultado.uso(), resultado.modelo(), milisegundosDesde(inicio));
        RespuestaAgente respuesta = switch (resultado) {
            case ResultadoBucle.Final fin -> analitica.presentar(GuardaDeAfirmaciones.revisar(fin.respuesta()), contexto,
                    arranque.mensajeId());
            case ResultadoBucle.Propuesta propuesta -> confirmacion(conversacionId, usuario, propuesta);
        };
        return cerrar(conversacionId, usuario, respuesta, consumo, seudonimos, traza, arranque.mensajeId());
    }

    /**
     * Un "si" escrito con una accion pendiente: no llega al modelo ni ejecuta nada; se recuerda el boton y se
     * vuelve a mostrar la accion. Pasa por la salida segura y el registro como cualquier otro turno.
     */
    private RespuestaAgente recordarConfirmacion(UUID conversacionId, UsuarioAgente usuario, String texto,
                                                 AccionPropuesta pendiente, TablaSeudonimos seudonimos,
                                                 TrazaTurno traza) {
        traza.pasar(EstadoTurno.INTENCION);
        registrador.iniciar(conversacionId, texto);
        traza.pasar(EstadoTurno.PERMISO_OK);
        traza.pasar(EstadoTurno.RECOLECTANDO);
        return cerrar(conversacionId, usuario,
                new RespuestaAgente.Confirmacion(TEXTO_USA_BOTON.formatted(pendiente.resumen()), pendiente),
                Consumo.NINGUNO, seudonimos, traza, RegistradorTurno.SIN_MENSAJE);
    }

    /**
     * El mensaje con los nombres que la persona escribio a medias y la conversacion ya conoce ("Luis Castro" es
     * Persona_3): si el modelo no vuelve a consultar en este turno, sin esto no los relaciona con sus alias. Solo
     * nombra lo que la persona ya escribio. La memoria guarda el mensaje sin la nota.
     */
    static String equivalencias(String dichoPorLaPersona, TablaSeudonimos seudonimos) {
        String pares = seudonimos.equivalencias(dichoPorLaPersona).entrySet().stream()
                .map(e -> "\"" + e.getValue() + "\" es " + e.getKey())
                .collect(Collectors.joining("; "));
        return pares.isEmpty() ? "" : "\n(Nombres que escribio la persona: " + pares + ".)";
    }

    /**
     * Una pregunta escrita como texto, sin consultar nada en el turno: igual que por pedir_datos_faltantes, se
     * devuelve una vez. Sin esto el modelo pide "el id del grupo" o nombra grupos que no leyo.
     */
    static Optional<String> preguntaSinConsultar(RespuestaAgente respuesta, TurnoContexto contexto) {
        return respuesta instanceof RespuestaAgente.Respuesta texto && pidePorTexto(texto.texto())
                ? PedirDatosFaltantesHerramienta.preguntaSinConsultar(contexto)
                : Optional.empty();
    }

    /** "¿Cual?" o, sin interrogacion, "dime de cual se trata y la consulto": pedirle a la persona un dato. */
    private static final Pattern PIDE_UN_DATO = Pattern.compile(
            "\\b(dime|dimelo|indica|indicame|especifica|especificame|confirmame|cuentame|aclarame)\\b");

    static boolean pidePorTexto(String texto) {
        return texto.contains("?") || PIDE_UN_DATO.matcher(NormalizadorTexto.plegar(texto)).find();
    }

    /** El borrador de turnos anteriores, solo si su herramienta se ofrece en este turno. */
    static String notaDeBorrador(Optional<BorradorAccion> borrador, Preparacion.Listo listo) {
        return borrador.flatMap(b -> listo.herramientas().stream()
                        .filter(h -> h.codigo().equals(b.herramienta()))
                        .findFirst()
                        .map(b::nota))
                .orElse("");
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

    /**
     * Pasa la respuesta por la salida segura, la guarda con seudonimos (memoria e historial vuelven al
     * modelo), con las llamadas a herramientas del turno delante, y la devuelve a la persona con los nombres reales.
     */
    private RespuestaAgente cerrar(UUID conversacionId, UsuarioAgente usuario, RespuestaAgente respuesta,
                                   Consumo consumo, TablaSeudonimos seudonimos, TrazaTurno traza,
                                   long mensajeIdUsuario) {
        RespuestaAgente revisada = SeudonimosRespuesta.ocultar(
                salida.revisar(respuesta, conversacionId, usuario.userId()), seudonimos);
        traza.pasar(EstadoTurno.de(revisada.tipo()));
        registrador.registrar(conversacionId, revisada, consumo, mensajeIdUsuario);
        almacenSeudonimos.guardar(conversacionId, seudonimos);
        traza.cerrar();
        return SeudonimosRespuesta.revelar(revisada, seudonimos);
    }

    private static long milisegundosDesde(long inicioNanos) {
        return (System.nanoTime() - inicioNanos) / NANOS_POR_MILISEGUNDO;
    }
}
