package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import com.co.eurekatic.aicontrol.agente.comun.ErrorAgente;
import com.co.eurekatic.aicontrol.agente.comun.UsuarioAgente;
import com.co.eurekatic.aicontrol.agente.persistencia.accion.AccionPendienteStore;
import com.co.eurekatic.aicontrol.agente.persistencia.accion.AccionPendienteStore.AccionPendiente;
import com.co.eurekatic.aicontrol.agente.persistencia.accion.EstadoAccion;
import com.co.eurekatic.aicontrol.agente.persistencia.conversacion.ConversacionStore;
import com.co.eurekatic.aicontrol.agente.persistencia.conversacion.ConversacionStore.Conversacion;
import com.co.eurekatic.aicontrol.agente.persistencia.conversacion.EstadoConversacion;
import com.co.eurekatic.aicontrol.agente.persistencia.mensaje.MensajeStore;
import com.co.eurekatic.aicontrol.agente.persistencia.mensaje.MensajeStore.Mensaje;
import com.co.eurekatic.aicontrol.agente.seguridad.seudonimos.AlmacenSeudonimos;
import com.co.eurekatic.aicontrol.agente.seguridad.seudonimos.TablaSeudonimos;
import org.springframework.stereotype.Service;
import tools.jackson.core.JacksonException;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

/**
 * Conversaciones del usuario: crear, listar, leer, archivar. Toda operacion sobre una conversacion
 * ajena se comporta como si no existiera.
 */
@Service
public class ConversacionesService {

    static final String TITULO_INICIAL = "Nueva conversación";
    private static final JsonMapper JSON = JsonMapper.builder().build();

    private final ConversacionStore conversaciones;
    private final MensajeStore mensajes;
    private final AlmacenSeudonimos seudonimos;
    private final AccionPendienteStore acciones;

    public ConversacionesService(ConversacionStore conversaciones, MensajeStore mensajes, AlmacenSeudonimos seudonimos,
                                 AccionPendienteStore acciones) {
        this.conversaciones = conversaciones;
        this.mensajes = mensajes;
        this.seudonimos = seudonimos;
        this.acciones = acciones;
    }

    public UUID crear(UsuarioAgente usuario) {
        return conversaciones.crear(usuario.userId(), TITULO_INICIAL).id();
    }

    public List<Conversacion> listar(UsuarioAgente usuario, int pagina, int tamano) {
        return conversaciones.listar(usuario.userId(), pagina, tamano);
    }

    /**
     * El historial se guarda con seudonimos; la persona lo ve con los nombres reales mientras la tabla de la
     * conversacion siga viva (dura lo mismo que la memoria). Despues, los alias quedan tal cual.
     *
     * <p>Cada accion pendiente que aparece en el historial lleva su estado actual: asi una conversacion
     * reabierta solo ofrece Confirmar/Cancelar mientras la accion siga PENDIENTE y vigente.
     */
    public Detalle detalle(UUID id, UsuarioAgente usuario) {
        Conversacion conversacion = propia(id, usuario);
        TablaSeudonimos tabla = seudonimos.cargar(id);
        List<Mensaje> reales = mensajes.listar(id).stream()
                .map(m -> new Mensaje(m.id(), m.conversacionId(), m.secuencia(), m.rol(),
                        m.contenido() == null ? null : tabla.revelar(m.contenido()), m.tipoRespuesta(),
                        m.accionesUi() == null ? null : tabla.revelar(m.accionesUi()), m.createdAt(),
                        m.respuesta() == null ? null : tabla.revelar(m.respuesta())))
                .toList();
        return new Detalle(conversacion, reales, estadosDeAcciones(id, usuario, reales));
    }

    /** Estado de cada accion citada en el historial; una PENDIENTE ya vencida se informa como EXPIRADA. */
    private Map<UUID, EstadoAccion> estadosDeAcciones(UUID conversacionId, UsuarioAgente usuario, List<Mensaje> lista) {
        Map<UUID, EstadoAccion> estados = new HashMap<>();
        Optional<UUID> vigente = Optional.empty();
        boolean vigenteConsultada = false;
        for (Mensaje m : lista) {
            Optional<UUID> accionId = accionPendienteId(m.respuesta());
            if (accionId.isEmpty() || estados.containsKey(accionId.get())) {
                continue;
            }
            Optional<AccionPendiente> accion = acciones.buscar(accionId.get(), usuario.userId());
            if (accion.isEmpty()) {
                continue;
            }
            EstadoAccion estado = accion.get().estado();
            if (estado == EstadoAccion.PENDIENTE) {
                // La vigencia la decide la base (su reloj), igual que al confirmar.
                if (!vigenteConsultada) {
                    vigente = acciones.pendienteVigente(conversacionId, usuario.userId()).map(AccionPendiente::id);
                    vigenteConsultada = true;
                }
                if (!vigente.equals(accionId)) {
                    estado = EstadoAccion.EXPIRADA;
                }
            }
            estados.put(accionId.get(), estado);
        }
        return Map.copyOf(estados);
    }

    static Optional<UUID> accionPendienteId(String respuestaJson) {
        if (respuestaJson == null) {
            return Optional.empty();
        }
        try {
            JsonNode id = JSON.readTree(respuestaJson).path("accionPendiente").path("id");
            return id.isString() ? Optional.of(UUID.fromString(id.asString())) : Optional.empty();
        } catch (JacksonException | IllegalArgumentException e) {
            return Optional.empty();
        }
    }

    /**
     * Comprueba que la conversacion es del usuario, sin mirar su estado.
     *
     * @throws ErrorAgente.ConversacionNoEncontrada si no existe o es ajena
     */
    public void verificar(UUID id, UsuarioAgente usuario) {
        propia(id, usuario);
    }

    public void archivar(UUID id, UsuarioAgente usuario) {
        if (!conversaciones.archivar(id, usuario.userId())) {
            throw new ErrorAgente.ConversacionNoEncontrada();
        }
    }

    /**
     * Conversacion propia que admite mensajes nuevos.
     *
     * @throws ErrorAgente.ConversacionNoEncontrada si no existe o es ajena
     * @throws ErrorAgente.ConversacionCerrada      si esta archivada o bloqueada
     */
    public Conversacion activa(UUID id, UsuarioAgente usuario) {
        Conversacion conversacion = propia(id, usuario);
        if (conversacion.estado() != EstadoConversacion.ACTIVA) {
            throw new ErrorAgente.ConversacionCerrada();
        }
        return conversacion;
    }

    private Conversacion propia(UUID id, UsuarioAgente usuario) {
        return conversaciones.buscar(id, usuario.userId()).orElseThrow(ErrorAgente.ConversacionNoEncontrada::new);
    }

    /**
     * Una conversacion con sus mensajes en orden.
     *
     * @param estadosAccion estado actual de cada accion pendiente citada en los mensajes
     */
    public record Detalle(Conversacion conversacion, List<Mensaje> mensajes, Map<UUID, EstadoAccion> estadosAccion) {

        public Detalle {
            mensajes = List.copyOf(mensajes);
            estadosAccion = Map.copyOf(estadosAccion);
        }

        public Detalle(Conversacion conversacion, List<Mensaje> mensajes) {
            this(conversacion, mensajes, Map.of());
        }
    }
}
