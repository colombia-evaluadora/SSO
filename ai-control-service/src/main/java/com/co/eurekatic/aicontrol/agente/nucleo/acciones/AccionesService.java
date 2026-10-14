package com.co.eurekatic.aicontrol.agente.nucleo.acciones;

import com.co.eurekatic.aicontrol.agente.catalogo.carga.CatalogoHerramientasLoader;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.RutaQuery;
import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.ArgumentosCanonicos;
import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.ConstructorPeticion;
import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.InvocadorHerramientas;
import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.Peticion;
import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.RegistroIds;
import com.co.eurekatic.aicontrol.agente.comun.ErrorAgente;
import com.co.eurekatic.aicontrol.agente.comun.Huellas;
import com.co.eurekatic.aicontrol.agente.comun.UsuarioAgente;
import com.co.eurekatic.aicontrol.agente.memoria.NotaDeMemoria;
import com.co.eurekatic.aicontrol.agente.nucleo.AccionPropuesta;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import com.co.eurekatic.aicontrol.agente.nucleo.turno.Consumo;
import com.co.eurekatic.aicontrol.agente.nucleo.turno.EstadoTurno;
import com.co.eurekatic.aicontrol.agente.nucleo.turno.RegistradorTurno;
import com.co.eurekatic.aicontrol.agente.persistencia.accion.AccionPendienteStore;
import com.co.eurekatic.aicontrol.agente.persistencia.accion.AccionPendienteStore.AccionPendiente;
import com.co.eurekatic.aicontrol.agente.persistencia.accion.AccionPendienteStore.NuevaAccion;
import com.co.eurekatic.aicontrol.agente.persistencia.accion.EstadoAccion;
import com.co.eurekatic.aicontrol.client.QueryServiceClient;
import com.co.eurekatic.aicontrol.client.RespuestaQuery;
import com.co.eurekatic.aicontrol.config.agente.AgenteProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;
import tools.jackson.databind.json.JsonMapper;

import java.time.Clock;
import java.time.Duration;
import java.time.LocalDateTime;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

/**
 * Propone, confirma y cancela las acciones de escritura. Fuera del modelo: una confirmacion nunca
 * pasa por el razonador.
 *
 * <p>Confirmar: busca la accion del usuario, comprueba estado, plazo y huella, la reclama con una
 * transicion condicional (la que gana ejecuta) y solo entonces llama al query-service con el token
 * de quien confirma. El resultado queda en la fila y en la conversacion.
 */
@Service
public class AccionesService {

    private static final Logger log = LoggerFactory.getLogger(AccionesService.class);
    private static final String MENSAJE_CANCELADA = "Acción cancelada. No se ha hecho ningún cambio.";
    private static final String MENSAJE_NO_DISPONIBLE = "Esa acción ya no está disponible. No se ha hecho ningún cambio.";
    private static final String MENSAJE_HECHO = NotaDeMemoria.PREFIJO_HECHO + "%s.";
    private static final String PREFIJO_AVISO = " Atención: ";
    private static final String MENSAJE_SERVIDOR =
            "No se pudo completar la acción por un problema del servicio académico. Revisa antes de volver a intentarlo.";
    private static final String MOTIVO_HUELLA = "HUELLA_NO_COINCIDE";

    private final AccionPendienteStore acciones;
    private final CatalogoHerramientasLoader catalogo;
    private final QueryServiceClient queryService;
    private final RegistradorTurno registrador;
    private final RegistroIds registroIds;
    private final Duration expira;
    private final Clock reloj;
    private final JsonMapper json = JsonMapper.builder().build();

    @Autowired
    public AccionesService(AccionPendienteStore acciones, CatalogoHerramientasLoader catalogo,
                           QueryServiceClient queryService, RegistradorTurno registrador, RegistroIds registroIds,
                           AgenteProperties props) {
        this(acciones, catalogo, queryService, registrador, registroIds, props.acciones().expira(),
                Clock.systemDefaultZone());
    }

    AccionesService(AccionPendienteStore acciones, CatalogoHerramientasLoader catalogo, QueryServiceClient queryService,
                    RegistradorTurno registrador, RegistroIds registroIds, Duration expira, Clock reloj) {
        this.acciones = acciones;
        this.catalogo = catalogo;
        this.queryService = queryService;
        this.registrador = registrador;
        this.registroIds = registroIds;
        this.expira = expira;
        this.reloj = reloj;
    }

    /** Guarda una escritura validada como pendiente y devuelve lo que el usuario debe confirmar. */
    public AccionPropuesta proponer(UUID conversacionId, UsuarioAgente usuario, HerramientaDef herramienta,
                                    ArgumentosCanonicos argumentos, String resumen) {
        String payload = CanonicoPayload.serializar(argumentos);
        AccionPendiente creada = acciones.crear(new NuevaAccion(conversacionId, usuario.userId(), herramienta.id(),
                payload, Huellas.sha256(payload), resumenConAviso(resumen, herramienta), expira));
        return new AccionPropuesta(creada.id(), creada.resumen(), creada.expiraAt());
    }

    /** Lo hecho, sin el aviso de confirmacion (ya no aplica) y sin doble punto final. */
    static String mensajeHecho(String resumen) {
        int aviso = resumen.indexOf(PREFIJO_AVISO);
        String accion = (aviso >= 0 ? resumen.substring(0, aviso) : resumen).strip();
        return MENSAJE_HECHO.formatted(accion.endsWith(".") ? accion.substring(0, accion.length() - 1) : accion);
    }

    /** Las escrituras que reemplazan un conjunto dicen, antes de confirmar, que daran de baja lo no incluido. */
    static String resumenConAviso(String resumen, HerramientaDef herramienta) {
        return herramienta.avisoConfirmacion()
                .map(aviso -> resumen + PREFIJO_AVISO + aviso)
                .orElse(resumen);
    }

    /** Confirma y ejecuta la accion. Como mucho una peticion la ejecuta. */
    public RespuestaAgente confirmar(UUID id, UsuarioAgente usuario) {
        AccionPendiente accion = pendiente(id, usuario);
        if (!acciones.transicionar(id, usuario.userId(), EstadoAccion.EJECUTADA, AccionPendienteStore.MARCA_EN_CURSO)) {
            throw new ErrorAgente.AccionNoPendiente();
        }
        RespuestaAgente respuesta = ejecutar(accion, usuario);
        registrador.registrar(accion.conversacionId(), respuesta, Consumo.NINGUNO);
        return respuesta;
    }

    /** Descarta una accion pendiente. Nada se ejecuta. */
    /** La accion de la conversacion que espera confirmacion, si la hay. */
    public Optional<AccionPropuesta> pendienteVigente(UUID conversacionId, UsuarioAgente usuario) {
        return acciones.pendienteVigente(conversacionId, usuario.userId())
                .map(a -> new AccionPropuesta(a.id(), a.resumen(), a.expiraAt()));
    }

    public RespuestaAgente cancelar(UUID id, UsuarioAgente usuario) {
        AccionPendiente accion = acciones.buscar(id, usuario.userId()).orElseThrow(ErrorAgente.AccionNoEncontrada::new);
        if (!acciones.transicionar(id, usuario.userId(), EstadoAccion.DESCARTADA, null)) {
            throw new ErrorAgente.AccionNoPendiente();
        }
        RespuestaAgente respuesta = new RespuestaAgente.Respuesta(MENSAJE_CANCELADA);
        registrador.registrar(accion.conversacionId(), respuesta, Consumo.NINGUNO);
        return respuesta;
    }

    /** Accion propia, pendiente, vigente y con la huella intacta. Si no, lanza el error de dominio. */
    private AccionPendiente pendiente(UUID id, UsuarioAgente usuario) {
        AccionPendiente accion = acciones.buscar(id, usuario.userId()).orElseThrow(ErrorAgente.AccionNoEncontrada::new);
        if (accion.estado() != EstadoAccion.PENDIENTE) {
            throw new ErrorAgente.AccionNoPendiente();
        }
        if (!LocalDateTime.now(reloj).isBefore(accion.expiraAt())) {
            // transicionar solo toca acciones vigentes; una vencida la cierra el barrido de expiradas.
            acciones.marcarExpiradas();
            throw new ErrorAgente.AccionExpirada();
        }
        if (!Huellas.sha256(CanonicoPayload.canonico(accion.payload())).equals(accion.payloadHash())) {
            acciones.transicionar(id, usuario.userId(), EstadoAccion.DESCARTADA, resultadoJson(EstadoAccion.DESCARTADA, MOTIVO_HUELLA));
            log.warn("Huella de accion no coincide: accion={}", id);
            throw new ErrorAgente.AccionAlterada();
        }
        return accion;
    }

    private RespuestaAgente ejecutar(AccionPendiente accion, UsuarioAgente usuario) {
        Optional<RutaQuery> ruta = herramientaVigente(accion.herramientaId()).flatMap(HerramientaDef::ruta);
        if (ruta.isEmpty()) {
            return cerrar(accion, EstadoAccion.FALLIDA, MENSAJE_NO_DISPONIBLE);
        }
        RespuestaQuery resultado = invocar(accion, ruta.get(), usuario);
        return switch (resultado) {
            case RespuestaQuery.Exito exito -> {
                // Lo que la escritura crea (el pk de la unidad nueva) es un id que la conversacion ya conoce.
                registroIds.registrar(accion.conversacionId().toString(), exito.filas());
                yield cerrar(accion, EstadoAccion.EJECUTADA, mensajeHecho(accion.resumen()));
            }
            case RespuestaQuery.ErrorCliente error -> cerrar(accion, EstadoAccion.FALLIDA, InvocadorHerramientas.traducir(error));
            case RespuestaQuery.ErrorServidor _ -> cerrar(accion, EstadoAccion.FALLIDA, MENSAJE_SERVIDOR);
        };
    }

    private RespuestaQuery invocar(AccionPendiente accion, RutaQuery ruta, UsuarioAgente usuario) {
        try {
            Peticion peticion = ConstructorPeticion.construir(ruta, CanonicoPayload.leer(accion.payload()));
            return queryService.invocar(peticion.metodo(), peticion.ruta(), peticion.query(), peticion.body(),
                    usuario.bearer());
        } catch (RuntimeException e) {
            log.error("No se pudo preparar la llamada de la accion {}: {}", accion.id(), e.getClass().getSimpleName());
            return new RespuestaQuery.ErrorServidor();
        }
    }

    /** Cierra la ejecucion reclamada con su resultado y devuelve el texto para el usuario. */
    private RespuestaAgente cerrar(AccionPendiente accion, EstadoAccion estadoFinal, String texto) {
        if (!acciones.completar(accion.id(), accion.fkUsuario(), estadoFinal, resultadoJson(estadoFinal, texto))) {
            log.warn("La accion {} ya no estaba en curso al cerrarla", accion.id());
        }
        log.info("Accion {} resuelta: {}", accion.id(), EstadoTurno.de(estadoFinal));
        return new RespuestaAgente.Respuesta(texto);
    }

    private Optional<HerramientaDef> herramientaVigente(long herramientaId) {
        return catalogo.catalogo().todas().stream()
                .filter(h -> h.id() == herramientaId && h.tipo().escribe())
                .findFirst();
    }

    private String resultadoJson(EstadoAccion estado, String mensaje) {
        return json.writeValueAsString(Map.of("estado", estado.name(), "mensaje", mensaje));
    }
}
