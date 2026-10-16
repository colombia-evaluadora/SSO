package com.co.eurekatic.comms.foro;

import com.co.eurekatic.comms.chat.ChatDtos.Filas;
import com.co.eurekatic.comms.chat.ChatDtos.Mensaje;
import com.co.eurekatic.comms.foro.ForoDtos.Etiqueta;
import com.co.eurekatic.comms.foro.ForoDtos.Foro;
import com.co.eurekatic.comms.foro.ForoDtos.Publicacion;
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
 * REST de los foros, mismo contrato que el mock del front
 * ({@code src/mocks/handlers/comunicaciones-foros.ts}): cuerpos UPPER_SNAKE, flags
 * {@code "S"|"N"} y sobre {@code {rows}}. Gateway: {@code /api/eval-col/comunicaciones/foros/**}.
 * El foro se crea con {@code POST /comunicaciones/conversaciones} y {@code TIPO: "FORO"}.
 */
@RestController
@RequestMapping("/comunicaciones/foros")
public class ForoController {

    public record EtiquetaIn(@JsonProperty("NOMBRE") String nombre, @JsonProperty("COLOR") String color,
                             @JsonProperty("SOLO_MODERADORES") String soloModeradores) { }

    public record PublicacionIn(@JsonProperty("TITULO") String titulo, @JsonProperty("TEXTO") String texto,
                                @JsonProperty("ETIQUETAS") List<Long> etiquetas,
                                @JsonProperty("ADJUNTO_NOMBRE") String adjuntoNombre,
                                @JsonProperty("ADJUNTO_FORMATO") String adjuntoFormato,
                                @JsonProperty("CLIENT_MESSAGE_ID") UUID clientMessageId) { }

    public record RespuestaIn(@JsonProperty("TEXTO") String texto, @JsonProperty("ADJUNTO_NOMBRE") String adjuntoNombre,
                              @JsonProperty("ADJUNTO_FORMATO") String adjuntoFormato,
                              @JsonProperty("FK_MENSAJE_RESPUESTA") Long respuesta,
                              @JsonProperty("CLIENT_MESSAGE_ID") UUID clientMessageId) { }

    public record EtiquetasIn(@JsonProperty("ETIQUETAS") List<Long> etiquetas) { }

    public record FijarIn(@JsonProperty("FIJADA") String fijada) { }

    public record CerrarIn(@JsonProperty("CERRADA") String cerrada) { }

    public record ResolverIn(@JsonProperty("RESUELTA") String resuelta,
                             @JsonProperty("FK_MENSAJE_SOLUCION") Long solucion) { }

    public record SeguirIn(@JsonProperty("SEGUIR") String seguir) { }

    private final ForoService foros;

    public ForoController(ForoService foros) {
        this.foros = foros;
    }

    private static boolean si(String flag) {
        return "S".equals(flag);
    }

    @GetMapping("/{canal}")
    public Filas<Foro> foro(HttpServletRequest r, @PathVariable long canal) {
        return Filas.de(foros.foro(Usuario.de(r), canal));
    }

    @PostMapping("/{canal}/etiquetas")
    public Filas<Etiqueta> crearEtiqueta(HttpServletRequest r, @PathVariable long canal, @RequestBody EtiquetaIn in) {
        return Filas.de(foros.crearEtiqueta(Usuario.de(r), canal, in.nombre(), in.color(), si(in.soloModeradores())));
    }

    @PatchMapping("/etiquetas/{id}/eliminar")
    public Filas<Etiqueta> eliminarEtiqueta(HttpServletRequest r, @PathVariable long id) {
        return Filas.de(foros.eliminarEtiqueta(Usuario.de(r), id));
    }

    @GetMapping("/{canal}/publicaciones")
    public Filas<Publicacion> publicaciones(HttpServletRequest r, @PathVariable long canal,
                                            @RequestParam(required = false) String orden,
                                            @RequestParam(required = false) Long etiqueta,
                                            @RequestParam(required = false) String q,
                                            @RequestParam(required = false) Integer pagina,
                                            @RequestParam(required = false) Integer limite) {
        return new Filas<>(foros.publicaciones(Usuario.de(r), canal, orden, etiqueta, q, pagina, limite));
    }

    @PostMapping("/{canal}/publicaciones")
    public Filas<Publicacion> publicar(HttpServletRequest r, @PathVariable long canal, @RequestBody PublicacionIn in) {
        return Filas.de(foros.publicar(Usuario.de(r), canal, in.titulo(), in.texto(), in.etiquetas(),
                in.adjuntoNombre(), in.adjuntoFormato(), in.clientMessageId()));
    }

    @GetMapping("/publicaciones/{id}")
    public Filas<Publicacion> publicacion(HttpServletRequest r, @PathVariable long id) {
        return Filas.de(foros.publicacion(Usuario.de(r), id));
    }

    @PatchMapping("/publicaciones/{id}")
    public Filas<Publicacion> editar(HttpServletRequest r, @PathVariable long id, @RequestBody PublicacionIn in) {
        return Filas.de(foros.editar(Usuario.de(r), id, in.titulo(), in.texto()));
    }

    @GetMapping("/publicaciones/{id}/respuestas")
    public Filas<Mensaje> respuestas(HttpServletRequest r, @PathVariable long id) {
        return new Filas<>(foros.respuestas(Usuario.de(r), id));
    }

    @PostMapping("/publicaciones/{id}/respuestas")
    public Filas<Mensaje> responder(HttpServletRequest r, @PathVariable long id, @RequestBody RespuestaIn in) {
        return Filas.de(foros.responder(Usuario.de(r), id, in.texto(), in.adjuntoNombre(), in.adjuntoFormato(),
                in.respuesta(), in.clientMessageId()));
    }

    @PatchMapping("/publicaciones/{id}/etiquetas")
    public Filas<Publicacion> etiquetar(HttpServletRequest r, @PathVariable long id, @RequestBody EtiquetasIn in) {
        return Filas.de(foros.etiquetar(Usuario.de(r), id, in.etiquetas()));
    }

    @PatchMapping("/publicaciones/{id}/fijar")
    public Filas<Publicacion> fijar(HttpServletRequest r, @PathVariable long id, @RequestBody FijarIn in) {
        return Filas.de(foros.fijar(Usuario.de(r), id, si(in.fijada())));
    }

    @PatchMapping("/publicaciones/{id}/cerrar")
    public Filas<Publicacion> cerrar(HttpServletRequest r, @PathVariable long id, @RequestBody CerrarIn in) {
        return Filas.de(foros.cerrar(Usuario.de(r), id, si(in.cerrada())));
    }

    @PatchMapping("/publicaciones/{id}/resolver")
    public Filas<Publicacion> resolver(HttpServletRequest r, @PathVariable long id, @RequestBody ResolverIn in) {
        return Filas.de(foros.resolver(Usuario.de(r), id, si(in.resuelta()), in.solucion()));
    }

    @PatchMapping("/publicaciones/{id}/seguir")
    public Filas<Publicacion> seguir(HttpServletRequest r, @PathVariable long id, @RequestBody SeguirIn in) {
        return Filas.de(foros.seguir(Usuario.de(r), id, si(in.seguir())));
    }

    @PatchMapping("/publicaciones/{id}/eliminar")
    public Filas<Publicacion> eliminar(HttpServletRequest r, @PathVariable long id) {
        return Filas.de(foros.eliminar(Usuario.de(r), id));
    }

    @PatchMapping("/respuestas/{id}/eliminar")
    public Filas<Mensaje> eliminarRespuesta(HttpServletRequest r, @PathVariable long id) {
        return Filas.de(foros.eliminarRespuesta(Usuario.de(r), id));
    }
}
