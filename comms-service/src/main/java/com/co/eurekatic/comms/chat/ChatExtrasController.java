package com.co.eurekatic.comms.chat;

import com.co.eurekatic.comms.chat.ChatDtos.ArchivoCompartido;
import com.co.eurekatic.comms.chat.ChatDtos.Borrador;
import com.co.eurekatic.comms.chat.ChatDtos.Conversacion;
import com.co.eurekatic.comms.chat.ChatDtos.Filas;
import com.co.eurekatic.comms.chat.ChatDtos.Mensaje;
import com.co.eurekatic.comms.security.Usuario;
import com.fasterxml.jackson.annotation.JsonProperty;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Borradores, archivos compartidos, duplicar canal y votacion rapida. Mismas
 * rutas y cuerpos que el mock del front ({@code src/mocks/handlers/comunicaciones.ts}).
 */
@RestController
@RequestMapping("/comunicaciones")
public class ChatExtrasController {

    public record BorradorIn(@JsonProperty("TEXTO") String texto) { }

    public record VotacionIn(@JsonProperty("PREGUNTA") String pregunta, @JsonProperty("TIPO") String tipo,
                             @JsonProperty("MINUTOS") Integer minutos) { }

    public record VotoIn(@JsonProperty("FK_OPCION") Integer opcion) { }

    private static final String NO_EDITABLE = "Este archivo no se puede editar.";

    private final ChatExtrasService extras;

    public ChatExtrasController(ChatExtrasService extras) {
        this.extras = extras;
    }

    // ── borradores ─────────────────────────────────────────────────────────

    @GetMapping("/borradores")
    public Filas<Borrador> borradores(HttpServletRequest r) {
        return new Filas<>(extras.borradores(Usuario.de(r)));
    }

    /** Lo que quedo escrito en el editor del canal; vacio lo descarta ({@code rows: []}). */
    @PutMapping("/conversaciones/{id}/borrador")
    public Filas<Borrador> guardarBorrador(HttpServletRequest r, @PathVariable long id, @RequestBody BorradorIn in) {
        return new Filas<>(extras.guardarBorrador(Usuario.de(r), id, in.texto()));
    }

    @PatchMapping("/borradores/{id}/enviar")
    public Filas<Borrador> enviarBorrador(HttpServletRequest r, @PathVariable long id) {
        return Filas.de(extras.enviarBorrador(Usuario.de(r), id));
    }

    @PatchMapping("/borradores/{id}/eliminar")
    public Filas<Borrador> eliminarBorrador(HttpServletRequest r, @PathVariable long id) {
        return Filas.de(extras.eliminarBorrador(Usuario.de(r), id));
    }

    // ── archivos ───────────────────────────────────────────────────────────

    @GetMapping("/archivos")
    public Filas<ArchivoCompartido> archivos(HttpServletRequest r) {
        return new Filas<>(extras.archivos(Usuario.de(r)));
    }

    /** Sin editor de documentos en el servidor: ningun adjunto es editable. */
    @GetMapping("/archivos/{id}/contenido")
    public Filas<Object> contenido(@PathVariable long id) {
        throw new ApiError(404, NO_EDITABLE);
    }

    @PutMapping("/archivos/{id}/contenido")
    public Filas<Object> guardarContenido(@PathVariable long id) {
        throw new ApiError(404, NO_EDITABLE);
    }

    @PatchMapping("/archivos/{id}/eliminar")
    public Filas<ArchivoCompartido> eliminarArchivo(HttpServletRequest r, @PathVariable long id) {
        return Filas.de(extras.eliminarArchivo(Usuario.de(r), id));
    }

    // ── duplicar ───────────────────────────────────────────────────────────

    @PostMapping("/conversaciones/{id}/duplicar")
    public Filas<Conversacion> duplicar(HttpServletRequest r, @PathVariable long id) {
        return Filas.de(extras.duplicar(Usuario.de(r), id));
    }

    // ── votacion rapida ────────────────────────────────────────────────────

    @PostMapping("/conversaciones/{id}/votaciones-rapidas")
    public Filas<Mensaje> crearVotacion(HttpServletRequest r, @PathVariable long id, @RequestBody VotacionIn in) {
        return Filas.de(extras.crearVotacion(Usuario.de(r), id, in.pregunta(), in.tipo(), in.minutos()));
    }

    @PatchMapping("/mensajes/{id}/votacion")
    public Filas<Mensaje> editarVotacion(HttpServletRequest r, @PathVariable long id, @RequestBody VotacionIn in) {
        return Filas.de(extras.editarVotacion(Usuario.de(r), id, in.pregunta(), in.tipo(), in.minutos()));
    }

    @PostMapping("/mensajes/{id}/votacion/votar")
    public Filas<Mensaje> votar(HttpServletRequest r, @PathVariable long id, @RequestBody VotoIn in) {
        return Filas.de(extras.votar(Usuario.de(r), id, in.opcion()));
    }
}
