package com.co.eurekatic.files;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.dao.EmptyResultDataAccessException;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

import java.net.URI;
import java.net.URISyntaxException;
import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Generador de URLs prefirmadas para archivos ya subidos a S3.
 *
 * <p>El cliente lo consume cuando el bucket no es público (caso
 * normal en producción): un {@code <img src=...>} o un
 * {@code window.open(url)} no funciona con la URL "pura" porque S3
 * responde 403. La solución estándar de AWS es firmar la URL — una
 * query string con SigV4 y una expiración corta (15 min por defecto)
 * que el SDK de S3 genera sin hacer una llamada de red al bucket.
 *
 * <p>Endpoint:
 * <pre>
 *   GET /files/sign/{archivoId}[?ttl=15]
 *   GET /files/sign/{archivoId}/{nombreDescarga}[?ttl=15]
 * </pre>
 *
 * <p>La segunda variante añade {@code response-content-disposition}
 * para que el navegador descargue con un nombre específico (útil
 * para PDFs/Word: el archivo se llama {@code plan.pdf} pero la
 * clave S3 es un UUID).
 *
 * <p><b>Por qué un servicio aparte y no una columna calculada en
 * query-service</b>: la firma necesita la
 * {@code secret_key} del bucket, que no debería vivir en la base
 * ni en query-service (que sólo lee). file-service ya tiene el
 * {@link AlmacenObjetos} con el cliente S3 — extenderlo es natural
 * y mantiene la credencial fuera del camino crítico del catálogo.
 *
 * <p><b>Por qué no va en el api-gateway</b>: idéntica razón que
 * {@code ReenvioController} — un fallo al firmar no debe tumbar el
 * resto de la API, y el gateway debe quedarse enrutando.
 */
@RestController
@RequestMapping("/files/sign")
public class FirmadorController {

    private static final Logger log = LoggerFactory.getLogger(FirmadorController.class);

    private final AlmacenObjetos almacen;
    private final NamedParameterJdbcTemplate jdbc;
    private final String schema;

    public FirmadorController(AlmacenObjetos almacen,
                              NamedParameterJdbcTemplate jdbc,
                              @Value("${files.schema:academico_test}") String schema) {
        this.almacen = almacen;
        this.jdbc = jdbc;
        this.schema = schema;
    }

    @GetMapping("/{archivoId}")
    public Map<String, Object> firmar(@PathVariable long archivoId,
                                      @org.springframework.web.bind.annotation.RequestParam(value = "ttl", required = false) Long ttlMinutos) {
        return firmarCon(archivoId, ttlMinutos, null);
    }

    @GetMapping("/{archivoId}/{nombreDescarga}")
    public Map<String, Object> firmarConDescarga(
            @PathVariable long archivoId,
            @PathVariable String nombreDescarga,
            @org.springframework.web.bind.annotation.RequestParam(value = "ttl", required = false) Long ttlMinutos) {
        // El cliente mete el nombre en la URL; cualquier comilla o
        // salto de línea se descarta por si intenta colarse un header
        // en la response-content-disposition (defensa barata — la
        // firma es SigV4, no por el nombre).
        String safe = nombreDescarga == null ? null
                : nombreDescarga.replaceAll("[\\r\\n\"]", "_");
        String disp = safe == null ? null
                : "attachment; filename=\"" + safe + "\"";
        return firmarCon(archivoId, ttlMinutos, disp);
    }

    private Map<String, Object> firmarCon(long archivoId, Long ttlMinutos,
                                          String disposition) {
        String clave = claveS3(archivoId);
        Duration ttl = (ttlMinutos == null || ttlMinutos <= 0)
                ? Duration.ofMinutes(15)
                : Duration.ofMinutes(Math.min(ttlMinutos, 24 * 60)); // tope 24h

        java.net.URL url = almacen.firmar(clave, ttl, disposition);

        Map<String, Object> resp = new LinkedHashMap<>();
        resp.put("archivoId", archivoId);
        resp.put("clave", clave);
        resp.put("ttlSegundos", ttl.toSeconds());
        resp.put("expiraEn", java.time.Instant.now().plus(ttl).toString());
        resp.put("url", url.toString());
        return resp;
    }

    /**
     * Lee {@code urls3} de {@code TARCHIVO} y devuelve la clave S3
     * (la parte después del bucket). Acepta dos formas en la fila:
     *
     * <ul>
     *   <li>{@code https://coleva-files.s3.amazonaws.com/sistema/.../foo.jpg}
     *       → clave = {@code sistema/.../foo.jpg}</li>
     *   <li>{@code s3://coleva-files/sistema/.../foo.jpg} → mismo destino</li>
     *   <li>{@code http://172.18.0.X:3900/eval-col/sistema/.../foo.jpg}
     *       (Garage local) → {@code sistema/.../foo.jpg}</li>
     * </ul>
     *
     * <p>Si el llamante ya tenía una clave cruda (sin esquema), se
     * devuelve tal cual — así el endpoint sigue siendo útil en
     * cargas mixtas mientras conviven AWS prod y Garage dev.
     */
    private String claveS3(long archivoId) {
        String urls3;
        try {
            urls3 = jdbc.queryForObject(
                    "SELECT urls3 FROM " + schema + ".tarchivo WHERE pk_tarchivo = :id",
                    new MapSqlParameterSource("id", archivoId),
                    String.class);
        } catch (EmptyResultDataAccessException e) {
            throw new ResponseStatusException(HttpStatus.NOT_FOUND,
                    "No existe tarchivo con id=" + archivoId);
        }
        if (urls3 == null || urls3.isBlank()) {
            throw new ResponseStatusException(HttpStatus.NOT_FOUND,
                    "tarchivo " + archivoId + " sin urls3 registrada");
        }
        String clave = extraerClave(urls3);
        if (clave == null || clave.isBlank()) {
            throw new ResponseStatusException(HttpStatus.UNPROCESSABLE_ENTITY,
                    "urls3 malformado para tarchivo " + archivoId + ": " + urls3);
        }
        log.debug("archivoId={} urls3={} -> clave={}", archivoId, urls3, clave);
        return clave;
    }

    /** {@code https://host/bucket/a/b/c.jpg} y {@code s3://bucket/a/b/c.jpg}
     *  → {@code a/b/c.jpg}. Si el path no se parece a una URL, lo devuelve
     *  entero asumiendo que ya era la clave. */
    static String extraerClave(String urls3) {
        try {
            if (urls3.startsWith("s3://")) {
                String sinEsquema = urls3.substring("s3://".length());
                int slash = sinEsquema.indexOf('/');
                return slash < 0 ? "" : sinEsquema.substring(slash + 1);
            }
            if (urls3.startsWith("http://") || urls3.startsWith("https://")) {
                URI uri = new URI(urls3);
                String path = uri.getPath(); // /bucket/a/b/c.jpg
                if (path == null || path.isBlank()) {
                    return null;
                }
                // Quita el "/<bucket>" inicial. Si después queda vacío,
                // significa que el path era solo "/<bucket>" sin clave.
                String sinSlash = path.startsWith("/") ? path.substring(1) : path;
                int slash = sinSlash.indexOf('/');
                return slash < 0 ? "" : sinSlash.substring(slash + 1);
            }
            return urls3;
        } catch (URISyntaxException e) {
            return null;
        }
    }
}
