package com.co.eurekatic.reporting.verificacion;

import org.springframework.http.HttpStatus;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

import java.util.Map;

/**
 * {@code POST /reportes/boletin/emisiones/{codigo}/revocar} con
 * {@code {"motivo": "..."}}: revoca el QR de un boletin impreso. Autenticado;
 * quien puede lo decide el gate de fn_boletin_emision_revocar (alcance de
 * establecimiento: rector, administracion del EE, territorial).
 */
@RestController
@RequestMapping("/reportes/boletin/emisiones")
public class EmisionController {

    private final EmisionBoletines emisiones;
    private final VerificacionPublicaService verificacion;

    public EmisionController(EmisionBoletines emisiones, VerificacionPublicaService verificacion) {
        this.emisiones = emisiones;
        this.verificacion = verificacion;
    }

    public record Revocacion(String motivo) {}

    @PostMapping("/{codigo}/revocar")
    public Map<String, Object> revocar(@PathVariable String codigo,
                                       @RequestBody(required = false) Revocacion body) {
        Map<String, Object> r = emisiones.revocar(codigo, body == null ? null : body.motivo(), token());
        verificacion.olvidar(codigo);
        return r;
    }

    private static String token() {
        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        if (auth == null || !(auth.getCredentials() instanceof String t) || t.isBlank()) {
            throw new ResponseStatusException(HttpStatus.UNAUTHORIZED, "Falta el token de la sesion.");
        }
        return t;
    }
}
