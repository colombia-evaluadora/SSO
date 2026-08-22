package com.co.eurekatic.reporting.web;

import org.springframework.http.ContentDisposition;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

import java.nio.charset.StandardCharsets;

/**
 * {@code POST /reportes/{clave}} — devuelve el archivo.
 *
 * <p>Responde el binario en el cuerpo, no una URL. Es lo que ya espera
 * el front (sus mutaciones de exportacion son un POST que termina en
 * una descarga) y evita tener que guardar el archivo en algun lado y
 * despues limpiarlo. Si algun reporte crece hasta tardar mas de lo que
 * aguanta el gateway, ese es el momento de pasarlo a asincronico con
 * file-service — no antes.
 */
@RestController
@RequestMapping("/reportes")
public class ReportController {

    private final ReportService service;

    public ReportController(ReportService service) {
        this.service = service;
    }

    @PostMapping("/{clave}")
    public ResponseEntity<byte[]> generar(@PathVariable String clave,
                                          @RequestBody(required = false) ReportRequest request) {

        ReportService.Rendered r = service.generate(clave, request, currentToken());

        HttpHeaders headers = new HttpHeaders();
        headers.setContentType(r.contentType());
        headers.setContentLength(r.content().length);
        // filename + filename* : el primero para clientes viejos, el
        // segundo (RFC 6266) para que las tildes del nombre no se rompan.
        headers.setContentDisposition(ContentDisposition.attachment()
                .filename(r.fileName(), StandardCharsets.UTF_8)
                .build());
        // Cabecera propia para que el front pueda avisar "se exportaron N
        // registros" sin tener que abrir el archivo.
        headers.add("X-Report-Rows", String.valueOf(r.rows()));

        return new ResponseEntity<>(r.content(), headers, HttpStatus.OK);
    }

    /**
     * El token crudo del usuario, que el filtro dejo como credentials.
     *
     * <p>Se reenvia tal cual al query-service: el reporte consulta CON LA
     * IDENTIDAD DE QUIEN LO PIDIO. Si aca hubiera una credencial de
     * servicio, cualquier usuario terminaria exportando lo que el
     * servicio puede ver, no lo que el puede ver.
     */
    private String currentToken() {
        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        if (auth == null || !(auth.getCredentials() instanceof String token) || token.isBlank()) {
            throw new ResponseStatusException(HttpStatus.UNAUTHORIZED,
                    "Falta el token de la sesion.");
        }
        return token;
    }
}
