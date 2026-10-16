package com.co.eurekatic.comms.realtime;

import com.co.eurekatic.comms.security.Usuario;
import com.fasterxml.jackson.databind.JsonNode;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.socket.CloseStatus;
import org.springframework.web.socket.TextMessage;
import org.springframework.web.socket.WebSocketSession;
import org.springframework.web.socket.handler.ConcurrentWebSocketSessionDecorator;

import java.io.IOException;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

/** Sockets abiertos en ESTA replica y los topicos a los que estan suscritos. */
@Component
public class SesionesLocales {

    private static final Logger log = LoggerFactory.getLogger(SesionesLocales.class);

    public record Conexion(WebSocketSession socket, Usuario usuario, Set<String> topicos) { }

    private final Map<String, Conexion> conexiones = new ConcurrentHashMap<>();

    public Conexion registrar(WebSocketSession s, Usuario u) {
        // Envios concurrentes seguros: tope de 10 s y 512 KB en cola por socket lento.
        var seguro = new ConcurrentWebSocketSessionDecorator(s, 10_000, 512 * 1024);
        Conexion c = new Conexion(seguro, u, ConcurrentHashMap.newKeySet());
        conexiones.put(s.getId(), c);
        return c;
    }

    public Conexion get(String id) {
        return conexiones.get(id);
    }

    public void quitar(String id) {
        conexiones.remove(id);
    }

    public void enviar(Conexion c, String txt) {
        try {
            if (c.socket().isOpen()) c.socket().sendMessage(new TextMessage(txt));
        } catch (IOException | IllegalStateException e) {
            log.debug("Socket {} no acepto el mensaje: {}", c.socket().getId(), e.getMessage());
        }
    }

    void entregar(String topic, JsonNode ev, String exceptoSub) {
        String txt = ev.toString();
        for (Conexion c : conexiones.values()) {
            if (c.topicos().contains(topic) && !c.usuario().sub().equals(exceptoSub)) enviar(c, txt);
        }
    }

    /** Cierra los sockets de un usuario (p. ej. expulsado de todo) con el codigo dado. */
    public void cerrarUsuario(String sub, int codigo) {
        for (Conexion c : conexiones.values()) {
            if (c.usuario().sub().equals(sub)) {
                try {
                    c.socket().close(new CloseStatus(codigo));
                } catch (IOException ignored) {
                    // ya cerrado
                }
            }
        }
    }

    public Iterable<Conexion> todas() {
        return conexiones.values();
    }
}
