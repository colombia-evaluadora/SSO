package com.co.eurekatic.notificationservice.bandeja;

import com.co.eurekatic.notificationservice.preferencias.PreferenciasDto.PreferenciasPayload;
import com.co.eurekatic.notificationservice.preferencias.PreferenciasDto.PreferenciasRow;
import com.co.eurekatic.notificationservice.preferencias.PreferenciasService;
import com.co.eurekatic.notificationservice.security.UsuarioActual;
import com.fasterxml.jackson.annotation.JsonProperty;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Set;
import java.util.UUID;

/**
 * API de la bandeja (front: {@code src/features/notificaciones/api/endpoints.ts}).
 * El gateway la expone en {@code /api/notificaciones/**} (StripPrefix=1).
 */
@RestController
@RequestMapping("/notificaciones")
public class BandejaController {

    static final int LIMITE_POR_DEFECTO = 30;
    static final int LIMITE_MAXIMO = 100;
    private static final Set<String> CATEGORIAS = Set.of(
            "CHAT", "LLAMADAS", "PLANEADOR", "ASISTENCIA", "INFORMES", "ESTABLECIMIENTO", "SISTEMA");

    public record PaginaRow(@JsonProperty("items") List<NotificacionFila> items,
                            @JsonProperty("next_cursor") String nextCursor) { }

    public record ContadorRow(@JsonProperty("no_leidas") long noLeidas) { }

    public record LeidaInput(Boolean leida) { }

    public record LeerTodasInput(String categoria) { }

    private final BandejaService bandeja;
    private final PreferenciasService preferencias;

    public BandejaController(BandejaService bandeja, PreferenciasService preferencias) {
        this.bandeja = bandeja;
        this.preferencias = preferencias;
    }

    @GetMapping
    public PaginaRow listar(HttpServletRequest req,
                            @RequestParam(required = false) String cursor,
                            @RequestParam(required = false) Integer limit,
                            @RequestParam(required = false) String categoria,
                            @RequestParam(required = false) String tipo,
                            @RequestParam(required = false) String estado,
                            @RequestParam(required = false) String texto) {
        int lim = limit == null ? LIMITE_POR_DEFECTO : Math.clamp(limit, 1, LIMITE_MAXIMO);
        Boolean leidas = switch (estado == null ? "" : estado) {
            case "leidas" -> Boolean.TRUE;
            case "no-leidas" -> Boolean.FALSE;
            default -> null;
        };
        String t = texto == null || texto.isBlank() ? null : texto.trim();
        if (t != null && t.length() > 200) t = t.substring(0, 200);
        var filtros = new BandejaRepository.Filtros(categoria(categoria), blanco(tipo), leidas, t);
        var pagina = bandeja.listar(UsuarioActual.de(req).sub(), filtros, Cursor.parse(cursor), lim);
        return new PaginaRow(pagina.items(), pagina.siguiente() == null ? null : pagina.siguiente().formato());
    }

    @GetMapping("/contador")
    public ContadorRow contador(HttpServletRequest req) {
        return new ContadorRow(bandeja.contador(UsuarioActual.de(req).sub()));
    }

    @PatchMapping("/{id}/leida")
    public ResponseEntity<Void> leida(HttpServletRequest req, @PathVariable UUID id,
                                      @RequestBody(required = false) LeidaInput in) {
        bandeja.marcarLeida(UsuarioActual.de(req).sub(), id, in == null || in.leida() == null || in.leida());
        return ResponseEntity.noContent().build();
    }

    @PostMapping("/leer-todas")
    public ResponseEntity<Void> leerTodas(HttpServletRequest req, @RequestBody(required = false) LeerTodasInput in) {
        bandeja.marcarTodasLeidas(UsuarioActual.de(req).sub(), in == null ? null : categoria(in.categoria()));
        return ResponseEntity.noContent().build();
    }

    @PatchMapping("/{id}/archivar")
    public ResponseEntity<Void> archivar(HttpServletRequest req, @PathVariable UUID id) {
        bandeja.archivar(UsuarioActual.de(req).sub(), id);
        return ResponseEntity.noContent().build();
    }

    @GetMapping("/preferencias")
    public PreferenciasRow preferencias(HttpServletRequest req) {
        return preferencias.resolver(UsuarioActual.de(req).sub());
    }

    @PutMapping("/preferencias")
    public PreferenciasRow guardarPreferencias(HttpServletRequest req, @RequestBody PreferenciasPayload body) {
        return preferencias.guardar(UsuarioActual.de(req).sub(), body);
    }

    private static String categoria(String c) {
        if (c == null || c.isBlank()) return null;
        if (!CATEGORIAS.contains(c)) throw new ApiException(400, "Categoria desconocida: " + c);
        return c;
    }

    private static String blanco(String s) {
        return s == null || s.isBlank() ? null : s.trim();
    }
}
