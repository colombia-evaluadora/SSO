package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import com.co.eurekatic.aicontrol.agente.comun.ErrorAgente;
import com.co.eurekatic.aicontrol.agente.comun.UsuarioAgente;
import com.co.eurekatic.aicontrol.agente.persistencia.conversacion.ConversacionStore;
import com.co.eurekatic.aicontrol.agente.persistencia.conversacion.ConversacionStore.Conversacion;
import com.co.eurekatic.aicontrol.agente.persistencia.conversacion.EstadoConversacion;
import com.co.eurekatic.aicontrol.agente.persistencia.mensaje.MensajeStore;
import com.co.eurekatic.aicontrol.agente.persistencia.mensaje.MensajeStore.Mensaje;
import org.springframework.stereotype.Service;

import java.util.List;
import java.util.UUID;

/**
 * Conversaciones del usuario: crear, listar, leer, archivar. Toda operacion sobre una conversacion
 * ajena se comporta como si no existiera.
 */
@Service
public class ConversacionesService {

    static final String TITULO_INICIAL = "Nueva conversación";

    private final ConversacionStore conversaciones;
    private final MensajeStore mensajes;

    public ConversacionesService(ConversacionStore conversaciones, MensajeStore mensajes) {
        this.conversaciones = conversaciones;
        this.mensajes = mensajes;
    }

    public UUID crear(UsuarioAgente usuario) {
        return conversaciones.crear(usuario.userId(), TITULO_INICIAL).id();
    }

    public List<Conversacion> listar(UsuarioAgente usuario, int pagina, int tamano) {
        return conversaciones.listar(usuario.userId(), pagina, tamano);
    }

    public Detalle detalle(UUID id, UsuarioAgente usuario) {
        Conversacion conversacion = propia(id, usuario);
        return new Detalle(conversacion, mensajes.listar(id));
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

    /** Una conversacion con sus mensajes en orden. */
    public record Detalle(Conversacion conversacion, List<Mensaje> mensajes) {

        public Detalle {
            mensajes = List.copyOf(mensajes);
        }
    }
}
