package com.co.eurekatic.files;

import com.co.eurekatic.common.security.JwtProperties;
import com.co.eurekatic.common.security.JwtTokenService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.ContentDisposition;
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
    private final JwtTokenService jwt;
    private final JwtProperties jwtProps;
    private final String tokenCompartido;

    public DownloadController(ArchivoRepository archivos,
                              AlmacenObjetos almacen,
                              JwtTokenService jwt,
                              JwtProperties jwtProps,
                              @Value("${files.internal-token:}") String tokenCompartido) {
        this.archivos = archivos;
        this.almacen = almacen;
        this.jwt = jwt;
        this.jwtProps = jwtProps;
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
            @RequestHeader(value = HttpHeaders.AUTHORIZATION, required = false) String autorizacion,
            @PathVariable("archivoId") long archivoId) {

        String quien = identificaLlamante(autorizacion, token);
        if (quien == null) {
            log.warn("descarga id={} rechazada: ni JWT válido ni token interno", archivoId);
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
            // El mensaje del bucket va en el log a propósito: un 400
            // de S3 casi nunca es "la clave está mal", es un problema
            // de configuración (región equivocada en la firma,
            // path-style desactivado contra un endpoint local,
            // credenciales de otro bucket). Sin el texto del error
            // hay que ir a los logs del propio S3 para enterarse, y
            // contra AWS eso no es una opción.
            log.error("descarga id={}: S3 respondió {} (clave={}): {}",
                    archivoId, e.statusCode(), clave,
                    e.awsErrorDetails() == null
                            ? e.getMessage()
                            : e.awsErrorDetails().errorMessage());
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
        // TARCHIVO no guarda mimetype, así que el content-type sale
        // de la extensión de la clave. Se pasa null como primer
        // argumento para dejar explícito que no es que lo hayamos
        // olvidado: no existe esa columna.
        headers.setContentType(mediaTypeDe(null, clave));
        // attachment vs inline: si el cliente es un <img> en el front,
        // inline; si es un "Descargar" explícito, attachment. El
        // catálogo puede pasar ?disposition=attachment vía query si
        // lo necesita — por ahora dejamos inline, que es lo que
        // esperan los <img src="..."> que ya tenían URLs prefirmadas.
        //
        // ContentDisposition.filename(nombre, UTF_8) y no un
        // "filename=\"...\"" armado a mano: TARCHIVO.nombre trae
        // nombres reales con tildes/ñ en filas históricas ("Recuperación
        // I Geo 6.docx" es un caso real, no hipotético — confirmado en
        // la tabla). Un header HTTP sólo admite ISO-8859-1; escribir el
        // carácter tal cual serializa un byte crudo (p.ej. 'ó' -> 0xF3)
        // que no es UTF-8 válido por sí solo, así que el navegador
        // muestra el nombre corrupto en el diálogo de "Guardar como"
        // aunque los bytes del archivo lleguen perfectos. El builder de
        // Spring sigue RFC 6266: emite un `filename*=UTF-8''<percent-
        // encoded>` para los clientes que lo entienden (todos los
        // navegadores modernos) y un `filename="..."` ASCII-seguro de
        // respaldo para el resto.
        headers.setContentDisposition(ContentDisposition.builder("inline")
                .filename(nombreSeguro(archivo.nombre()), StandardCharsets.UTF_8)
                .build());

        // El tamaño lo manda S3, no la fila. TARCHIVO.peso se escribió
        // al subir y puede haber quedado desincronizado (o NULL en
        // filas antiguas); anunciar un Content-Length que no coincide
        // con los bytes que se van a escribir deja al navegador
        // esperando datos que no llegan, o truncando la descarga.
        // El GetObjectResponse trae el valor real del objeto.
        Long tamano = objeto.response().contentLength();
        if (tamano == null || tamano <= 0) {
            tamano = archivo.peso() > 0 ? archivo.peso() : null;
        }
        if (tamano != null) {
            headers.setContentLength(tamano);
        }
        // Sin Content-Length, Tomcat usa chunked por su cuenta; no hay
        // que ponerlo a mano (hacerlo es un error: es un header
        // hop-by-hop que el contenedor gestiona él mismo).

        log.info("descarga id={} ({} bytes) para {}", archivoId, tamano, quien);
        return ResponseEntity.ok().headers(headers).body(cuerpo);
    }

    /**
     * Identifica a quien pide el archivo, por cualquiera de las dos
     * vías legítimas. Devuelve una etiqueta para el log, o
     * {@code null} si no se pudo autenticar por ninguna.
     *
     * <p>Son dos porque hay dos clases de llamante, y ninguna puede
     * usar el mecanismo de la otra:
     *
     * <ul>
     *   <li><b>Un usuario</b> (el admin-ui pidiendo la firma de un
     *       funcionario) llega con su JWT. Se verifica la FIRMA, no
     *       la mera presencia de la cabecera.</li>
     *   <li><b>El catálogo</b>, cuando arma un enlace en una respuesta,
     *       actúa por su cuenta y no tiene JWT de usuario ninguno que
     *       presentar. Para eso está el secreto compartido.</li>
     * </ul>
     *
     * <p>Se prueba primero el JWT porque es el caso normal; el token
     * interno es la excepción.
     */
    private String identificaLlamante(String autorizacion, String tokenInterno) {
        String prefijo = jwtProps.tokenPrefix();
        if (autorizacion != null && autorizacion.startsWith(prefijo)) {
            String bruto = autorizacion.substring(prefijo.length()).trim();
            if (!bruto.isEmpty()) {
                try {
                    return "usuario:" + jwt.parse(bruto).email();
                } catch (io.jsonwebtoken.JwtException e) {
                    // Token presente pero inválido (caducado, firma que
                    // no cuadra). No se cae al token interno: quien
                    // manda un JWT roto quería entrar como usuario, y
                    // devolver 401 dice exactamente eso.
                    log.debug("JWT rechazado: {}", e.getMessage());
                    return null;
                }
            }
        }
        return verificaTokenInterno(tokenInterno) ? "catálogo" : null;
    }

    /**
     * Compara el token recibido con el configurado en tiempo constante.
     * Devuelve false si la variable está vacía: un despliegue sin
     * token configurado debe fallar cerrado, no abierto.
     */
    private boolean verificaTokenInterno(String recibido) {
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
            if (path == null || path.isBlank() || path.equals("/")) {
                return null;
            }
            String sinBarra = path.substring(1);
            // Aquí hay que distinguir los dos estilos de URL de S3,
            // porque en uno el bucket va en el path y en el otro no:
            //
            //   path-style     http://host:3900/eval-col/a/b.jpg
            //                  → el bucket ES el primer segmento
            //   virtual-hosted https://coleva-files.s3.amazonaws.com/a/b.jpg
            //                  → el bucket va en el HOST; el path
            //                    entero es ya la clave
            //
            // Confundirlos corrompe la clave en silencio: aplicar la
            // regla de path-style a una URL virtual-hosted le arranca
            // el primer segmento real de la clave (en las filas
            // históricas, el "sistema/" inicial) y S3 responde 404.
            if (esVirtualHosted(uri.getHost())) {
                return sinBarra;
            }
            int idx = sinBarra.indexOf('/');
            if (idx < 0 || idx == sinBarra.length() - 1) {
                return null;
            }
            return sinBarra.substring(idx + 1);
        } catch (IllegalArgumentException e) {
            return null;
        }
    }

    /**
     * ¿El host lleva el bucket delante, al estilo
     * {@code <bucket>.s3.amazonaws.com} / {@code <bucket>.s3.<region>.amazonaws.com}?
     *
     * <p>Se mira el host y no una lista de buckets conocidos a
     * propósito: este servicio no sabe qué buckets existieron
     * históricamente, y las filas de TARCHIVO son de hace años.
     */
    private static boolean esVirtualHosted(String host) {
        if (host == null) {
            return false;
        }
        String h = host.toLowerCase();
        // "s3.amazonaws.com" a secas es path-style (el bucket viene
        // en el path); sólo es virtual-hosted si hay algo DELANTE.
        return (h.contains(".s3.") || h.contains(".s3-"))
                && h.endsWith("amazonaws.com");
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
