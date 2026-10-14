package com.co.eurekatic.reporting.verificacion;

import jakarta.servlet.http.HttpServletRequest;
import org.springframework.http.CacheControl;
import org.springframework.http.ContentDisposition;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

/**
 * Verificacion publica del boletin, SIN sesion (permitAll aqui y en el
 * gateway):
 *
 * <ul>
 *   <li>{@code GET /reportes/public/boletin/{codigo}}: estado, fechas,
 *       establecimiento, sede y periodo. Nada del estudiante.</li>
 *   <li>{@code POST /reportes/public/boletin/{codigo}/pdf} con
 *       {@code {"ultimos4": "1234"}}: el boletin actual con marca de agua,
 *       solo si coinciden los 4 ultimos caracteres del documento.</li>
 * </ul>
 *
 * <p>La IP sale de {@code X-Client-Ip}, que el gateway sobrescribe siempre
 * con la del socket (el cliente no puede falsearla).
 */
@RestController
@RequestMapping("/reportes/public/boletin")
public class VerificacionPublicaController {

    static final String CABECERA_IP = "X-Client-Ip";

    private final VerificacionPublicaService servicio;
    private final LimitesVerificacion limites;

    public VerificacionPublicaController(VerificacionPublicaService servicio,
                                         LimitesVerificacion limites) {
        this.servicio = servicio;
        this.limites = limites;
    }

    public record SegundoFactor(String ultimos4) {}

    @GetMapping("/{codigo}")
    public ResponseEntity<Map<String, Object>> estado(@PathVariable String codigo,
                                                      HttpServletRequest req) {
        limites.contarPeticion(ip(req));
        return ResponseEntity.ok()
                .cacheControl(CacheControl.noStore())
                .header("X-Robots-Tag", "noindex")
                .body(servicio.estado(codigo));
    }

    @PostMapping("/{codigo}/pdf")
    public ResponseEntity<byte[]> pdf(@PathVariable String codigo,
                                      @RequestBody(required = false) SegundoFactor factor,
                                      HttpServletRequest req) {
        limites.contarPeticion(ip(req));
        byte[] pdf = servicio.pdf(codigo, factor == null ? null : factor.ultimos4());
        HttpHeaders h = new HttpHeaders();
        h.setContentType(MediaType.APPLICATION_PDF);
        h.setContentLength(pdf.length);
        h.setContentDisposition(ContentDisposition.inline().filename("boletin-verificacion.pdf").build());
        h.setCacheControl(CacheControl.noStore());
        h.set("X-Robots-Tag", "noindex");
        return ResponseEntity.ok().headers(h).body(pdf);
    }

    static String ip(HttpServletRequest req) {
        String h = req.getHeader(CABECERA_IP);
        return h == null || h.isBlank() ? req.getRemoteAddr() : h.trim();
    }
}
