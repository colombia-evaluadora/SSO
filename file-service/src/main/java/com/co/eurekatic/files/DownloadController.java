package com.co.eurekatic.files;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.servlet.mvc.method.annotation.StreamingResponseBody;
import software.amazon.awssdk.core.ResponseInputStream;
import software.amazon.awssdk.services.s3.model.GetObjectRequest;
import software.amazon.awssdk.services.s3.model.GetObjectResponse;
import software.amazon.awssdk.services.s3.model.NoSuchKeyException;
import software.amazon.awssdk.services.s3.model.S3Exception;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;

/**
 * Descarga de archivos a través del api-gateway.
 *
 * <p>Este servicio <strong>no</strong> entrega URLs prefirmadas al
 * navegador. La razón es una decisión de arquitectura, no un capricho:
 * las URLs prefirmadas apuntan al endpoint interno de S3 (Garage en
 * local, AWS en prod). Para que el navegador pudiera consumirlas habría
 * que exponer Garage directamente al front, lo que:
 *
 * <ul>
 *   <li>rompe el patrón de "todo pasa por el gateway" del SSO;</li>
 *   <li>filtra credenciales — Garage respondería 200 incluso si el
 *       usuario ya cerró sesión, porque la firma es válida mientras
 *       no expire;</li>
 *   <li>obliga al front a conocer dos hosts distintos (gateway para
 *       APIs, Garage para binarios) y gestionar CORS / cookies /
 *       sesiones en cada uno por separado.</li>
 * </ul>
 *
 * <p>En su lugar: el front pide {@code GET /api/files/download/{id}}.
 * El gateway enruta hacia acá. Este controller saca el objeto de S3
 * y lo streamea al response, así el navegador sólo conoce el gateway.
 * Si el usuario pierde la sesión, el gateway rechaza con 401 antes de
 * llegar a este código.
 *
 * <p>La autenticación interna con {@code X-Internal-Token} existe
 * porque este endpoint también es consumido por el catálogo cuando el
 * procedimiento PL/pgSQL necesita un enlace temporal al archivo —
 * llamadas que vienen del propio backend, no del navegador. La
 * verificación en este controller es independiente de la del gateway:
 * si en el futuro la ruta del gateway cambia, este método sigue
 * protegiendo el endpoint directamente, sin acoplar la seguridad del
 * catálogo a la del API-gateway.
 */
@RestController
public class DownloadController {

    private static final Logger log = LoggerFactory.getLogger(DownloadController.class);

    private static final String INTERNAL_HEADER = "X-Internal-Token";

    private final ArchivoRepository archivos;
    private final AlmacenObjetos almacen;
    private final String tokenCompartido;

    public DownloadController(ArchivoRepository archivos,
                              AlmacenObjetos almacen,
                              @Value("${files.internal-token:}") String tokenCompartido) {
        this.archivos = archivos;
        this.almacen = almacen;
        this.tokenCompartido = tokenCompartido == null ? "" : tokenCompartido;
    }

    /**
     * Stream del archivo al response. 401 si el token interno no viene
     * o no coincide (comparación en tiempo constante para evitar timing
     * attacks contra el secreto compartido). 404 si no hay fila activa
     * con ese id. 502 si S3/Garage rechaza la operación.
     */
    @GetMapping("/files/download/{archivoId}")
    public ResponseEntity<StreamingResponseBody> descargar(
            @RequestHeader(value = INTERNAL_HEADER, required = false) String token,
            @PathVariable("archivoId") long archivoId) {

        if (!verificaToken(token)) {
            log.warn("descarga id={} rechazada: token interno ausente o inválido", archivoId);
            return ResponseEntity.status(401).build();
        }

        var archivo = archivos.buscarActivo(archivoId).orElse(null);
        if (archivo == null) {
            log.warn("descarga id={} rechazada: fila no encontrada o inactiva", archivoId);
            return ResponseEntity.notFound().build();
        }

        String clave = extraerClave(archivo.urls3());
        if (clave == null) {
            // urls3 debería ser s3://bucket/key o https://host/bucket/key.
            // Si no encaja, devolvemos 502 — es un dato corrupto, no
            // un archivo que el cliente pidió mal.
            log.warn("descarga id={}: urls3 malformado: {}", archivoId, archivo.urls3());
            return ResponseEntity.status(502).build();
        }

        ResponseInputStream<GetObjectResponse> objeto;
        try {
            objeto = almacen.abrir(clave);
        } catch (NoSuchKeyException e) {
            // Hay fila pero no hay bytes: pasó la reserva pero la
            // subida nunca cerró — o un job de limpieza borró el
            // objeto pero todavía no la fila. Devolvemos 404 al
            // front y logueamos para revisar.
            log.warn("descarga id={}: fila activa pero objeto ausente en S3 (clave={})",
                    archivoId, clave);
            return ResponseEntity.notFound().build();
        } catch (S3Exception e) {
            log.error("descarga id={}: S3 respondió {} (clave={})",
                    archivoId, e.statusCode(), clave);
            return ResponseEntity.status(502).build();
        }

        StreamingResponseBody cuerpo = (OutputStream out) -> {
            // try-with-resources NO funciona aquí: el header ya se
            // escribió cuando Spring aceptó la respuesta; el stream
            // hay que cerrarlo manualmente en el finally.
            try (InputStream in = objeto) {
                in.transferTo(out);
            } catch (IOException e) {
                // Cliente se desconectó a mitad de la descarga. No es
                // un error que valga la pena reportar como 5xx — el
                // log a nivel DEBUG basta para diagnóstico.
                log.debug("descarga id={} interrumpida por el cliente: {}",
                        archivoId, e.getMessage());
            }
        };

        HttpHeaders headers = new HttpHeaders();
        headers.setContentType(mediaTypeDe(archivo.mimetype(), clave));
        // attachment vs inline: si el cliente es un <img> en el front,
        // inline; si es un "Descargar" explícito, attachment. El
        // catálogo puede pasar ?disposition=attachment vía query si
        // lo necesita — por ahora dejamos inline, que es lo que
        // esperan los <img src="..."> que ya tenían URLs prefirmadas.
        headers.set(HttpHeaders.CONTENT_DISPOSITION,
                "inline; filename=\"" + nombreSeguro(archivo.nombre()) + "\"");

        Long tamano = archivo.peso();
        if (tamano != null && tamano > 0) {
            headers.setContentLength(tamano);
        } else {
            // Si la fila no tiene peso (caso de cargas previas a este
            // campo), caemos al header de S3 — pero el cliente de
            // Garage puede no devolverlo siempre. Content-Length es
            // opcional en HTTP/1.1; los browsers saben chunkear.
            headers.set(HttpHeaders.TRANSFER_ENCODING, "chunked");
        }

        return ResponseEntity.ok().headers(headers).body(cuerpo);
    }

    /**
     * Compara el token recibido con el configurado en tiempo constante.
     * Devuelve false si la variable está vacía: un despliegue sin
     * token configurado debe fallar cerrado, no abierto.
     */
    private boolean verificaToken(String recibido) {
        if (tokenCompartido.isEmpty() || recibido == null) {
            return false;
        }
        byte[] esperado = tokenCompartido.getBytes(StandardCharsets.UTF_8);
        byte[] dado = recibido.getBytes(StandardCharsets.UTF_8);
        return MessageDigest.isEqual(esperado, dado);
    }

    /**
     * Extrae la clave S3 de una URL registrada en {@code TARCHIVO.URLS3}.
     *
     * <p>Acepta tres formas:
     * <ul>
     *   <li>{@code s3://bucket/key/sub/path} — lo que genera el
     *       AlmacenObjetos cuando no hay publicBase;</li>
     *   <li>{@code http(s)://host/bucket/key/sub/path} — lo que se
     *       genera cuando sí hay publicBase;</li>
     *   <li>{@code key/sub/path} — clave cruda, SIN esquema. Es la
     *       forma en la que están escritas la mayoría de las filas
     *       históricas de TARCHIVO (p.ej.
     *       {@code ACADEMICO_VALLEDUPAR/120001003751/actividad/463900.pdf}),
     *       y hay que devolverla tal cual. Pasarla por el mismo
     *       "quítale el primer segmento" que las URLs le arrancaría
     *       el {@code ACADEMICO_VALLEDUPAR} y pediría a S3 una clave
     *       que no existe — 404 en vez del archivo, sin ninguna
     *       pista en el log de por qué.</li>
     * </ul>
     *
     * <p>Devuelve {@code null} sólo si la entrada está vacía o si es
     * una URL de la que no se puede extraer clave — preferimos un
     * 502 explícito a propagar una clave vacía que S3 rechazaría con
     * un 400 confuso.
     */
    static String extraerClave(String urls3) {
        if (urls3 == null || urls3.isBlank()) {
            return null;
        }
        if (urls3.startsWith("s3://")) {
            // s3://bucket/key
            String resto = urls3.substring("s3://".length());
            int slash = resto.indexOf('/');
            return slash < 0 ? null : resto.substring(slash + 1);
        }
        // Sin esquema http(s) = ya es la clave. El check es sobre el
        // prefijo y no sobre "¿parsea como URI?" a propósito: una
        // clave cruda TAMBIÉN parsea como URI relativa, así que
        // preguntarle a URI no distingue los dos casos.
        if (!urls3.startsWith("http://") && !urls3.startsWith("https://")) {
            return urls3;
        }
        try {
            URI uri = URI.create(urls3);
            String path = uri.getPath();
            if (path == null || path.isBlank()) {
                return null;
            }
            // /bucket/key/sub -> quitamos el primer segmento (bucket).
            int idx = path.indexOf('/', 1);
            if (idx < 0 || idx == path.length() - 1) {
                return null;
            }
            return path.substring(idx + 1);
        } catch (IllegalArgumentException e) {
            return null;
        }
    }

    /**
     * Devuelve el MediaType del archivo. Si la fila trae mimetype
     * (preferido) lo respeta; si no, intenta adivinarlo por la
     * extensión de la clave; si tampoco, octet-stream.
     */
    static MediaType mediaTypeDe(String mimetype, String clave) {
        if (mimetype != null && !mimetype.isBlank()) {
            return MediaType.parseMediaType(mimetype);
        }
        int punto = clave.lastIndexOf('.');
        if (punto < 0 || punto == clave.length() - 1) {
            return MediaType.APPLICATION_OCTET_STREAM;
        }
        return switch (clave.substring(punto + 1).toLowerCase()) {
            case "pdf" -> MediaType.APPLICATION_PDF;
            case "png" -> MediaType.IMAGE_PNG;
            case "jpg", "jpeg" -> MediaType.IMAGE_JPEG;
            case "gif" -> MediaType.IMAGE_GIF;
            case "webp" -> MediaType.parseMediaType("image/webp");
            case "svg" -> MediaType.parseMediaType("image/svg+xml");
            case "txt" -> MediaType.TEXT_PLAIN;
            case "json" -> MediaType.APPLICATION_JSON;
            case "xml" -> MediaType.APPLICATION_XML;
            default -> MediaType.APPLICATION_OCTET_STREAM;
        };
    }

    /**
     * Limpia el nombre de archivo para que no rompa el header
     * Content-Disposition. Reemplaza comillas y caracteres de
     * control — los nombres con espacios o tildes se quedan tal cual.
     */
    static String nombreSeguro(String nombre) {
        if (nombre == null || nombre.isBlank()) {
            return "archivo";
        }
        return nombre.replace("\"", "'").replaceAll("[\\p{Cntrl}]", "");
    }
}
