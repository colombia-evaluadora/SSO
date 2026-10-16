package com.co.eurekatic.notificationservice.push;

import com.co.eurekatic.notificationservice.bandeja.ApiException;
import com.co.eurekatic.notificationservice.push.PushSuscripcionRepository.SuscripcionRow;
import com.co.eurekatic.notificationservice.security.UsuarioActual;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.net.URI;
import java.security.GeneralSecurityException;
import java.util.List;
import java.util.Map;

/**
 * Suscripciones Web Push del usuario (front: {@code push/api/push-api.ts}).
 * Solo se aceptan endpoints {@code https}: el push service es siempre HTTPS y
 * asi el servicio no se puede usar para hacer peticiones a la red interna.
 */
@RestController
@RequestMapping("/notificaciones/push")
public class PushSuscripcionController {

    public record ClavesInput(String p256dh, String auth) { }

    public record SuscripcionInput(String endpoint, ClavesInput keys, String userAgent, String plataforma) { }

    public record BajaInput(String endpoint) { }

    private final PushSuscripcionRepository repo;
    private final VapidClaves vapid;

    public PushSuscripcionController(PushSuscripcionRepository repo, VapidClaves vapid) {
        this.repo = repo;
        this.vapid = vapid;
    }

    @GetMapping("/vapid-public-key")
    public Map<String, String> clavePublica() {
        return Map.of("publicKey", vapid.publica().orElseThrow(
                () -> new ApiException(503, "Las notificaciones push no estan configuradas.")));
    }

    @GetMapping("/suscripciones")
    public List<SuscripcionRow> listar(HttpServletRequest req) {
        return repo.listar(UsuarioActual.de(req).sub());
    }

    @PostMapping("/suscripciones")
    public ResponseEntity<SuscripcionRow> crear(HttpServletRequest req, @RequestBody SuscripcionInput in) {
        if (in == null || in.endpoint() == null || in.keys() == null
                || in.keys().p256dh() == null || in.keys().auth() == null) {
            throw new ApiException(400, "Suscripcion invalida.");
        }
        validarEndpoint(in.endpoint());
        try {
            WebPushCrypto.publicKey(WebPushCrypto.b64(in.keys().p256dh()));
            if (WebPushCrypto.b64(in.keys().auth()).length != 16) throw new GeneralSecurityException("auth");
        } catch (GeneralSecurityException | IllegalArgumentException e) {
            throw new ApiException(400, "Suscripcion invalida.");
        }
        SuscripcionRow row = repo.guardar(UsuarioActual.de(req).sub(), in.endpoint(), in.keys().p256dh(),
                in.keys().auth(), recortar(in.userAgent(), 500), recortar(in.plataforma(), 50));
        return ResponseEntity.status(HttpStatus.CREATED).body(row);
    }

    @DeleteMapping("/suscripciones")
    public ResponseEntity<Void> bajaPorEndpoint(HttpServletRequest req, @RequestBody(required = false) BajaInput in) {
        if (in == null || in.endpoint() == null) throw new ApiException(400, "Falta el endpoint.");
        repo.borrarPorEndpoint(UsuarioActual.de(req).sub(), in.endpoint());
        return ResponseEntity.noContent().build();
    }

    @DeleteMapping("/suscripciones/{id}")
    public ResponseEntity<Void> baja(HttpServletRequest req, @PathVariable long id) {
        if (!repo.borrar(UsuarioActual.de(req).sub(), id)) throw new ApiException(404, "No encontrada.");
        return ResponseEntity.noContent().build();
    }

    static void validarEndpoint(String endpoint) {
        try {
            URI uri = URI.create(endpoint);
            if (!"https".equalsIgnoreCase(uri.getScheme()) || uri.getHost() == null || endpoint.length() > 2000) {
                throw new ApiException(400, "Suscripcion invalida.");
            }
        } catch (IllegalArgumentException e) {
            throw new ApiException(400, "Suscripcion invalida.");
        }
    }

    private static String recortar(String s, int max) {
        if (s == null) return null;
        return s.length() <= max ? s : s.substring(0, max);
    }
}
