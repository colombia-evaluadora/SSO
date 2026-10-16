package com.co.eurekatic.comms.chat;

import com.co.eurekatic.comms.chat.ChatDtos.Conversacion;
import com.co.eurekatic.comms.chat.ChatDtos.Filas;
import com.co.eurekatic.comms.chat.ChatDtos.Mensaje;
import com.co.eurekatic.comms.chat.ChatDtos.Miembro;
import com.co.eurekatic.comms.chat.ChatDtos.Persona;
import com.co.eurekatic.comms.security.Usuario;
import com.fasterxml.jackson.annotation.JsonProperty;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.UUID;

/**
 * REST del chat, mismas rutas, cuerpos UPPER_SNAKE y sobre {@code {rows}} que
 * el mock del front ({@code src/mocks/handlers/comunicaciones.ts}). El gateway
 * enruta {@code /api/eval-col/comunicaciones/**} aqui (StripPrefix=2), asi el
 * front no cambia de cliente ({@code evalCol}).
 */
@RestController
@RequestMapping("/comunicaciones")
public class ChatController {

    public record CanalIn(@JsonProperty("NOMBRE") String nombre, @JsonProperty("CATEGORIA") String categoria,
                          @JsonProperty("MIEMBROS") List<Long> miembros, @JsonProperty("TIPO") String tipo) { }

    public record MiembrosIn(@JsonProperty("MIEMBROS") List<Long> miembros) { }

    public record BloqueoIn(@JsonProperty("BLOQUEADO") Boolean bloqueado) { }

    public record DirectoIn(@JsonProperty("FK_PERSONA") Long persona) { }

    public record SilencioIn(@JsonProperty("DURACION") String duracion) { }

    public record MensajeIn(@JsonProperty("TEXTO") String texto, @JsonProperty("ADJUNTO_NOMBRE") String adjuntoNombre,
                            @JsonProperty("ADJUNTO_FORMATO") String adjuntoFormato,
                            @JsonProperty("FK_MENSAJE_RESPUESTA") Long respuesta,
                            @JsonProperty("CLIENT_MESSAGE_ID") UUID clientMessageId) { }

    public record EmojiIn(@JsonProperty("EMOJI") String emoji) { }

    public record FijarIn(@JsonProperty("FIJADO") String fijado) { }

    private final ChatService chat;
    private final PoliticaChat politica;

    public ChatController(ChatService chat, PoliticaChat politica) {
        this.chat = chat;
        this.politica = politica;
    }

    @GetMapping("/conversaciones")
    public Filas<Conversacion> conversaciones(HttpServletRequest r) {
        return new Filas<>(chat.conversaciones(Usuario.de(r)));
    }

    @GetMapping("/politica")
    public Filas<ChatDtos.Politica> politica() {
        return Filas.de(politica.dto());
    }

    @GetMapping("/personas")
    public Filas<Persona> personas(HttpServletRequest r, @RequestParam(required = false) String q) {
        return new Filas<>(chat.personas(Usuario.de(r), q));
    }

    @PostMapping("/conversaciones")
    public Filas<Conversacion> crear(HttpServletRequest r, @RequestBody CanalIn in) {
        return Filas.de(chat.crearCanal(Usuario.de(r), in.nombre(), in.categoria(), in.miembros(), in.tipo()));
    }

    @PatchMapping("/conversaciones/{id}")
    public Filas<Conversacion> renombrar(HttpServletRequest r, @PathVariable long id, @RequestBody CanalIn in) {
        return Filas.de(chat.renombrar(Usuario.de(r), id, in.nombre()));
    }

    @GetMapping("/conversaciones/{id}/miembros")
    public Filas<Miembro> miembros(HttpServletRequest r, @PathVariable long id) {
        return new Filas<>(chat.miembros(Usuario.de(r), id));
    }

    @PostMapping("/conversaciones/{id}/miembros")
    public Filas<Miembro> agregar(HttpServletRequest r, @PathVariable long id, @RequestBody MiembrosIn in) {
        return new Filas<>(chat.agregarMiembros(Usuario.de(r), id, in.miembros()));
    }

    @PatchMapping("/conversaciones/{id}/miembros/{miembro}/bloquear")
    public Filas<Miembro> bloquear(HttpServletRequest r, @PathVariable long id, @PathVariable long miembro,
                                   @RequestBody BloqueoIn in) {
        return Filas.de(chat.bloquear(Usuario.de(r), id, miembro, Boolean.TRUE.equals(in.bloqueado())));
    }

    @PatchMapping("/conversaciones/{id}/miembros/{miembro}/eliminar")
    public Filas<Miembro> quitar(HttpServletRequest r, @PathVariable long id, @PathVariable long miembro) {
        return Filas.de(chat.quitarMiembro(Usuario.de(r), id, miembro));
    }

    @PostMapping("/directos")
    public Filas<Conversacion> directo(HttpServletRequest r, @RequestBody DirectoIn in) {
        return Filas.de(chat.directo(Usuario.de(r), in.persona()));
    }

    @GetMapping("/conversaciones/{id}/mensajes")
    public Filas<Mensaje> mensajes(HttpServletRequest r, @PathVariable long id,
                                   @RequestParam(required = false) Long antes,
                                   @RequestParam(required = false) Integer limite) {
        return new Filas<>(chat.mensajes(Usuario.de(r), id, antes, limite));
    }

    @PostMapping("/conversaciones/{id}/mensajes")
    public Filas<Mensaje> enviar(HttpServletRequest r, @PathVariable long id, @RequestBody MensajeIn in) {
        return Filas.de(chat.enviar(Usuario.de(r), id, in.texto(), in.adjuntoNombre(), in.adjuntoFormato(),
                in.respuesta(), in.clientMessageId()));
    }

    @PatchMapping("/conversaciones/{id}/silenciar")
    public Filas<Conversacion> silenciar(HttpServletRequest r, @PathVariable long id, @RequestBody SilencioIn in) {
        return Filas.de(chat.silenciar(Usuario.de(r), id, in.duracion()));
    }

    @PatchMapping("/conversaciones/{id}/leido")
    public Filas<Conversacion> leido(HttpServletRequest r, @PathVariable long id) {
        return Filas.de(chat.leido(Usuario.de(r), id));
    }

    @PatchMapping("/conversaciones/{id}/no-leido")
    public Filas<Conversacion> noLeido(HttpServletRequest r, @PathVariable long id) {
        return Filas.de(chat.noLeido(Usuario.de(r), id));
    }

    @PatchMapping("/conversaciones/{id}/archivar")
    public Filas<Conversacion> archivar(HttpServletRequest r, @PathVariable long id) {
        return Filas.de(chat.archivar(Usuario.de(r), id, true));
    }

    @PatchMapping("/conversaciones/{id}/desarchivar")
    public Filas<Conversacion> desarchivar(HttpServletRequest r, @PathVariable long id) {
        return Filas.de(chat.archivar(Usuario.de(r), id, false));
    }

    @PatchMapping("/conversaciones/{id}/eliminar")
    public Filas<Conversacion> eliminar(HttpServletRequest r, @PathVariable long id) {
        return Filas.de(chat.eliminar(Usuario.de(r), id));
    }

    @PatchMapping("/conversaciones/{id}/salir")
    public Filas<Conversacion> salir(HttpServletRequest r, @PathVariable long id) {
        return Filas.de(chat.salir(Usuario.de(r), id));
    }

    @PostMapping("/mensajes/{id}/reacciones")
    public Filas<Mensaje> reaccionar(HttpServletRequest r, @PathVariable long id, @RequestBody EmojiIn in) {
        return Filas.de(chat.reaccionar(Usuario.de(r), id, in.emoji()));
    }

    @PatchMapping("/mensajes/{id}/fijar")
    public Filas<Mensaje> fijar(HttpServletRequest r, @PathVariable long id, @RequestBody FijarIn in) {
        return Filas.de(chat.fijar(Usuario.de(r), id, "S".equals(in.fijado())));
    }

    @PatchMapping("/mensajes/{id}/adjunto/eliminar")
    public Filas<Mensaje> quitarAdjunto(HttpServletRequest r, @PathVariable long id) {
        return Filas.de(chat.quitarAdjunto(Usuario.de(r), id));
    }

    @PatchMapping("/mensajes/{id}/eliminar")
    public Filas<Mensaje> eliminarMensaje(HttpServletRequest r, @PathVariable long id) {
        return Filas.de(chat.eliminarMensaje(Usuario.de(r), id));
    }

    @PatchMapping("/mensajes/{id}")
    public Filas<Mensaje> editar(HttpServletRequest r, @PathVariable long id, @RequestBody MensajeIn in) {
        return Filas.de(chat.editar(Usuario.de(r), id, in.texto()));
    }
}
