package com.co.eurekatic.files;

import com.co.eurekatic.common.query.ParamTypes;
import com.co.eurekatic.common.security.JwtProperties;
import com.co.eurekatic.common.security.JwtTokenService;
import jakarta.servlet.http.HttpServletRequest;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.ContentDisposition;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestParam;
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
import java.util.Map;
import java.util.Set;

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
 *
 * <p><b>{@code /files/view/{id}} — visualización directa en
 * {@code <img src="...">}.</b> {@code /files/download/{id}} exige
 * {@code Authorization: Bearer} en la cabecera, algo que un
 * {@code <img>} plano del navegador no puede mandar (por eso el front
 * lo consume con {@code fetch()} + blob URL). Cuando SÍ hace falta un
 * {@code <img src>} directo, el flujo es en dos pasos: (1) el front,
 * ya autenticado, pide {@code POST /files/view-token/{id}} y recibe
 * un token de un solo archivo, de vida corta ({@link ViewTokenService});
 * (2) ese token va en la URL de la imagen —
 * {@code <img src="/files/view/{id}?token=...">} — que el navegador sí
 * puede pedir sin cabeceras. {@code /files/view/{id}} acepta ese
 * token O un JWT normal, así que sigue sirviendo también al caso
 * {@code fetch()} existente sin duplicar código de streaming.
 *
 * <p><b>{@code /files/public/**} — activos globales, sin auth y sin
 * expirar.</b> {@code /files/view/{id}} resuelve el caso "{@code <img
 * src>} autenticado" con un token de vida corta; no sirve para un
 * dato de catálogo ({@code tlista_valor.valor}, p.ej.) que se guarda
 * una vez y se renderiza indefinidamente después — un token de 5
 * minutos ahí obligaría a re-mintarlo en cada carga. Este tercer
 * endpoint no pide nada: la clave S3 completa va en la ruta, y la
 * única puerta es que su clasificación esté en {@link
 * com.co.eurekatic.common.query.ParamTypes#PUBLIC_FILE_CLASSIFICATIONS}
 * (hoy, íconos de calificación — nunca nada por-usuario o
 * por-establecimiento). Ver {@link #publico}.
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
    private final ViewTokenService viewTokens;
    private final FileAccessService acceso;

    public DownloadController(ArchivoRepository archivos,
                              AlmacenObjetos almacen,
                              JwtTokenService jwt,
                              JwtProperties jwtProps,
                              @Value("${files.internal-token:}") String tokenCompartido,
                              ViewTokenService viewTokens,
                              FileAccessService acceso) {
        this.archivos = archivos;
        this.almacen = almacen;
        this.jwt = jwt;
        this.jwtProps = jwtProps;
        this.tokenCompartido = tokenCompartido == null ? "" : tokenCompartido;
        this.viewTokens = viewTokens;
        this.acceso = acceso;
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
            @PathVariable("archivoId") long archivoId,
            @RequestParam(value = "mimeType", required = false) String mimeType) {

        Llamante llamante = identificaLlamante(autorizacion, token);
        if (llamante == null) {
            log.warn("descarga id={} rechazada: ni JWT válido ni token interno", archivoId);
            return ResponseEntity.status(401).build();
        }
        if (llamante.esUsuario() && !acceso.puedeVer(archivoId, llamante.email(), llamante.roles())) {
            // 404 y no 403 a propósito: distinguir "no es tuyo" de "no
            // existe" le regala a quien prueba ids al azar la
            // confirmación de que un id concreto SÍ tiene fila activa.
            log.warn("descarga id={} rechazada: {} sin permiso sobre este archivo",
                    archivoId, llamante.etiqueta());
            return ResponseEntity.notFound().build();
        }
        return streamear(archivoId, llamante.etiqueta(), mimeType);
    }

    /**
     * Acuña un token de vista para {@code archivoId} — ver javadoc de
     * clase. Exige el mismo JWT que {@code descargar}: emitir el token
     * es una acción de sesión normal, sólo lo que se hace CON el token
     * (pedir {@code /files/view/{id}}) es lo que no puede llevar
     * cabeceras. 404 si el archivo no existe o está inactivo — no tiene
     * sentido acuñar un acceso a algo que {@code /files/view} va a
     * rechazar igual.
     */
    @PostMapping("/files/view-token/{archivoId}")
    public ResponseEntity<Map<String, Object>> emitirTokenVista(
            @RequestHeader(value = HttpHeaders.AUTHORIZATION, required = false) String autorizacion,
            @PathVariable("archivoId") long archivoId) {

        Llamante llamante = identificaLlamante(autorizacion, null);
        if (llamante == null) {
            return ResponseEntity.status(401).build();
        }
        if (!viewTokens.habilitado()) {
            log.error("view-token id={}: files.view-token-secret no configurado", archivoId);
            return ResponseEntity.status(503).build();
        }
        if (archivos.buscarActivo(archivoId).isEmpty()) {
            return ResponseEntity.notFound().build();
        }
        // Acuñar el token ES otorgar el acceso: quien no podría ver el
        // archivo directamente tampoco puede llevarse un token que se
        // lo entregue por otra puerta.
        if (llamante.esUsuario() && !acceso.puedeVer(archivoId, llamante.email(), llamante.roles())) {
            log.warn("view-token id={} rechazado: {} sin permiso sobre este archivo",
                    archivoId, llamante.etiqueta());
            return ResponseEntity.notFound().build();
        }
        String token = viewTokens.acunar(archivoId);
        log.info("view-token id={} acuñado para {} (ttl={}s)", archivoId, llamante.etiqueta(), viewTokens.ttlSegundos());
        return ResponseEntity.ok(Map.of(
                "token", token,
                // Con el prefijo /api: el cliente que llama a este endpoint
                // ES el navegador, y llega SIEMPRE a través del gateway
                // (route "api-file-service", StripPrefix=1 —
                // /api/files/** -> /files/** en este servicio). Sin el
                // prefijo, la URL de conveniencia apunta a una ruta que el
                // gateway no reconoce y el <img> recibe 401 en vez de la
                // imagen — la propia ruta interna que este controller
                // expone (/files/view/...) nunca es la que el navegador
                // debe pedir directamente.
                "url", "/api/files/view/" + archivoId + "?token=" + token,
                "expiresIn", viewTokens.ttlSegundos()));
    }

    /**
     * Sirve el archivo para visualización directa — pensado para
     * {@code <img src="...">}. Acepta el JWT normal (mismo camino que
     * {@code descargar}) O un token de vista en {@code ?token=}; no
     * hace falta elegir uno en el cliente, se prueban ambos.
     */
    @GetMapping("/files/view/{archivoId}")
    public ResponseEntity<StreamingResponseBody> ver(
            @RequestHeader(value = HttpHeaders.AUTHORIZATION, required = false) String autorizacion,
            @RequestParam(value = "token", required = false) String token,
            @PathVariable("archivoId") long archivoId,
            @RequestParam(value = "mimeType", required = false) String mimeType) {

        Llamante llamante = identificaLlamante(autorizacion, null);
        if (llamante == null) {
            if (!viewTokens.valido(token, archivoId)) {
                log.warn("view id={} rechazada: ni JWT válido ni token de vista", archivoId);
                return ResponseEntity.status(401).build();
            }
            // El token de vista ya es, en sí mismo, la autorización:
            // se acuñó en emitirTokenVista() después de pasar este
            // mismo chequeo. No se repite aquí.
            return streamear(archivoId, "token-vista", mimeType);
        }
        if (llamante.esUsuario() && !acceso.puedeVer(archivoId, llamante.email(), llamante.roles())) {
            log.warn("view id={} rechazada: {} sin permiso sobre este archivo",
                    archivoId, llamante.etiqueta());
            return ResponseEntity.notFound().build();
        }
        return streamear(archivoId, llamante.etiqueta(), mimeType);
    }

    /**
     * V67 — activos gráficos GLOBALES de la interfaz (caritas/símbolos
     * de calificación), servidos sin JWT ni token de vista: a
     * diferencia de {@link #ver}, esto está pensado para un
     * {@code <img src>} que vive para siempre en un dato de catálogo
     * ({@code tlista_valor.valor}), no para un archivo por-usuario con
     * un token que expira en minutos.
     *
     * <p>La ruta trae la CLAVE S3 completa, tal cual está guardada en
     * {@code TARCHIVO.urls3} ({@code /files/public/ACADEMICO_VALLEDUPAR/graficaCarita/489905.png}
     * → clave {@code ACADEMICO_VALLEDUPAR/graficaCarita/489905.png}).
     * Dos puertas, ambas obligatorias, antes de tocar S3:
     *
     * <ol>
     *   <li>La CLASIFICACIÓN de la clave (el segmento inmediatamente
     *       antes del nombre de archivo — ver {@link #clasificacionDe})
     *       tiene que estar en {@link ParamTypes#PUBLIC_FILE_CLASSIFICATIONS}.
     *       Una clave con clasificación {@code actividad},
     *       {@code matricula}, etc. — CUALQUIER cosa fuera de ese set —
     *       responde 404 sin más, aunque el objeto exista de verdad:
     *       este endpoint nunca es la puerta para datos por-usuario o
     *       por-establecimiento.</li>
     *   <li>Tiene que haber una fila ACTIVA en {@code TARCHIVO} con
     *       {@code urls3} EXACTAMENTE igual a la clave pedida — ver
     *       {@link ArchivoRepository#buscarActivoPorClave}. Sin esto,
     *       un objeto huérfano (fila borrada, bytes que quedaron en el
     *       bucket) seguiría siendo servible para siempre.</li>
     * </ol>
     *
     * <p>404 y no 403 en ambos casos: no hay nada que "pedir permiso"
     * — una clave que no cumple no es un recurso protegido, es un
     * recurso que no existe desde el punto de vista de este endpoint.
     */
    @GetMapping("/files/public/**")
    public ResponseEntity<StreamingResponseBody> publico(
            HttpServletRequest peticion,
            @RequestParam(value = "mimeType", required = false) String mimeType) {

        String clave = claveDeLaPeticion(peticion);
        if (clave == null) {
            return ResponseEntity.notFound().build();
        }
        String clasificacion = clasificacionDe(clave);
        if (clasificacion == null || !ParamTypes.PUBLIC_FILE_CLASSIFICATIONS.contains(clasificacion)) {
            log.debug("público rechazado: clasificación '{}' no es pública (clave={})", clasificacion, clave);
            return ResponseEntity.notFound().build();
        }
        var archivo = archivos.buscarActivoPorClave(clave).orElse(null);
        if (archivo == null) {
            log.warn("público rechazado: sin fila activa para clave={}", clave);
            return ResponseEntity.notFound().build();
        }
        return streamearArchivo(archivo, mimeType, "público:" + clasificacion);
    }

    /**
     * Streaming común a {@code descargar}, {@code ver} y
     * {@code publico}: resolver la clave S3, abrir el objeto y
     * devolverlo con los headers de siempre. Los tres endpoints
     * difieren sólo en CÓMO se autoriza al llamante y en cómo llegan a
     * la fila de {@code TARCHIVO} — una vez que la tienen, sirven
     * exactamente el mismo archivo de la misma forma.
     */
    private ResponseEntity<StreamingResponseBody> streamear(long archivoId, String quien, String mimeType) {
        var archivo = archivos.buscarActivo(archivoId).orElse(null);
        if (archivo == null) {
            log.warn("acceso id={} rechazado: fila no encontrada o inactiva", archivoId);
            return ResponseEntity.notFound().build();
        }
        return streamearArchivo(archivo, mimeType, quien);
    }

    private ResponseEntity<StreamingResponseBody> streamearArchivo(
            ArchivoRepository.Archivo archivo, String mimeType, String quien) {
        long archivoId = archivo.pkTarchivo();

        MediaType tipoForzado = null;
        if (mimeType != null && !mimeType.isBlank()) {
            try {
                tipoForzado = MediaType.parseMediaType(mimeType);
            } catch (org.springframework.http.InvalidMediaTypeException e) {
                // ?mimeType= inválido: 400 en vez de servir el archivo
                // con un content-type adivinado que el llamante no
                // pidió. Quien lo manda ya sabe qué es el archivo (ver
                // javadoc de clase) — un valor roto es un bug del
                // llamante, no algo que se pueda ignorar en silencio.
                log.warn("acceso id={}: ?mimeType={} no es un media type válido", archivoId, mimeType);
                return ResponseEntity.badRequest().build();
            }
        }

        String clave = extraerClave(archivo.urls3());
        if (clave == null) {
            // urls3 debería ser s3://bucket/key o https://host/bucket/key.
            // Si no encaja, devolvemos 502 — es un dato corrupto, no
            // un archivo que el cliente pidió mal.
            log.warn("acceso id={}: urls3 malformado: {}", archivoId, archivo.urls3());
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
            log.warn("acceso id={}: fila activa pero objeto ausente en S3 (clave={})",
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
            log.error("acceso id={}: S3 respondió {} (clave={}): {}",
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
                log.debug("acceso id={} interrumpido por el cliente: {}",
                        archivoId, e.getMessage());
            }
        };

        HttpHeaders headers = new HttpHeaders();
        // TARCHIVO no guarda mimetype, así que por defecto el
        // content-type sale de la extensión de la clave. Cuando el
        // llamante manda ?mimeType= (el endpoint o query de negocio
        // que YA sabe qué es este archivo — p.ej. "esto siempre es un
        // jpeg de perfilUsuario" — gana sobre la adivinanza: filas
        // como perfilUsuario guardan el nombre real en TARCHIVO.nombre
        // (un email o un documento de identidad, sin extensión) y sólo
        // la clave S3 trae el sufijo, así que dejarle al llamante
        // fijar el tipo evita depender de que ese sufijo siempre esté
        // bien puesto.
        headers.setContentType(tipoForzado != null ? tipoForzado : mediaTypeDe(null, clave));
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

        log.info("acceso id={} ({} bytes) para {}", archivoId, tamano, quien);
        return ResponseEntity.ok().headers(headers).body(cuerpo);
    }

    /**
     * Identifica a quien pide el archivo, por cualquiera de las dos
     * vías legítimas. Devuelve {@code null} si no se pudo autenticar
     * por ninguna.
     *
     * <p>Son dos porque hay dos clases de llamante, y ninguna puede
     * usar el mecanismo de la otra:
     *
     * <ul>
     *   <li><b>Un usuario</b> (el admin-ui pidiendo la firma de un
     *       funcionario) llega con su JWT. Se verifica la FIRMA, no
     *       la mera presencia de la cabecera. {@link Llamante#esUsuario()}
     *       es true, y trae email + roles para el chequeo de
     *       {@link FileAccessService}.</li>
     *   <li><b>El catálogo</b>, cuando arma un enlace en una respuesta,
     *       actúa por su cuenta y no tiene JWT de usuario ninguno que
     *       presentar. Para eso está el secreto compartido — y por lo
     *       mismo no pasa por {@link FileAccessService}: ya es un
     *       llamante de confianza, no alguien a quien haya que
     *       preguntarle "¿es tuyo este archivo?".</li>
     * </ul>
     *
     * <p>Se prueba primero el JWT porque es el caso normal; el token
     * interno es la excepción.
     */
    private Llamante identificaLlamante(String autorizacion, String tokenInterno) {
        String prefijo = jwtProps.tokenPrefix();
        if (autorizacion != null && autorizacion.startsWith(prefijo)) {
            String bruto = autorizacion.substring(prefijo.length()).trim();
            if (!bruto.isEmpty()) {
                try {
                    var principal = jwt.parse(bruto);
                    return new Llamante("usuario:" + principal.email(),
                            principal.email(), principal.roles());
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
        return verificaTokenInterno(tokenInterno) ? new Llamante("catálogo", null, null) : null;
    }

    /**
     * Quien pide el archivo, ya identificado. {@code email}/{@code roles}
     * son {@code null} para el catálogo (token interno) — ese llamante
     * no pasa por {@link FileAccessService#puedeVer}, así que no hacen
     * falta. {@link #esUsuario()} es la señal de "sí hacen falta".
     */
    private record Llamante(String etiqueta, String email, Set<String> roles) {
        boolean esUsuario() {
            return email != null;
        }
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
     * V67 — todo lo que venga después de {@code /files/public/} en la
     * ruta pedida, tal cual (es la clave S3 completa, puede traer
     * varios segmentos). {@code null} si la petición no cae bajo ese
     * prefijo o si no queda nada después de él.
     *
     * <p>Se lee {@code PATH_WITHIN_HANDLER_MAPPING_ATTRIBUTE} en vez
     * de construir la ruta a mano, mismo patrón que
     * {@code ReenvioController#rutaDestino} — es el valor que Spring
     * ya calculó al resolver el {@code /**}, sin que este método tenga
     * que lidiar con querystring ni con cómo vino codificado.
     */
    private static String claveDeLaPeticion(HttpServletRequest peticion) {
        String ruta = (String) peticion.getAttribute(
                org.springframework.web.servlet.HandlerMapping.PATH_WITHIN_HANDLER_MAPPING_ATTRIBUTE);
        if (ruta == null) {
            ruta = peticion.getRequestURI();
        }
        String prefijo = "/files/public/";
        if (ruta == null || !ruta.startsWith(prefijo)) {
            return null;
        }
        String clave = ruta.substring(prefijo.length());
        return clave.isBlank() ? null : clave;
    }

    /**
     * V67 — la clasificación de una clave S3 es el segmento
     * INMEDIATAMENTE ANTERIOR al nombre de archivo, sin importar
     * cuántos segmentos vengan antes ({@code <sitio>/}, {@code
     * <establecimiento>/}, o ninguno de los dos — ver
     * {@code TransformadorMultipart#claveDe}): para
     * {@code ACADEMICO_VALLEDUPAR/graficaCarita/489905.png} es
     * {@code graficaCarita}; para
     * {@code ACADEMICO_VALLEDUPAR/120001003751/actividad/463900.pdf}
     * es {@code actividad}. {@code null} si la clave no tiene ni un
     * separador ({@code "489905.png"} a secas, el formato genérico sin
     * clasificar) — nunca es pública, porque no HAY clasificación que
     * mirar.
     */
    static String clasificacionDe(String clave) {
        String[] partes = clave.split("/");
        return partes.length < 2 ? null : partes[partes.length - 2];
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
