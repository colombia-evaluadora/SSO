package com.co.eurekatic.files;

import jakarta.servlet.http.HttpServletRequest;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.RestClient;
import org.springframework.web.multipart.MultipartFile;
import org.springframework.web.multipart.MultipartHttpServletRequest;
import org.springframework.web.server.ResponseStatusException;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Un solo POST desde el cliente.
 *
 * <p>Recibe el multipart, lo transforma en JSON (cada binario pasa a
 * ser su {@code pk_tarchivo}) y lo reenvía al mismo path del catálogo,
 * donde un procedimiento decide qué hacer con los ids.
 *
 * <pre>
 *   POST /files/eval-col/funcionario   (multipart)
 *        └─ sube, registra, transforma
 *        └─ POST /api/eval-col/funcionario   (JSON)
 * </pre>
 *
 * <p><b>Por qué no va esto en el api-gateway</b>: sería más transparente
 * —mismo path, sin prefijo— pero pondría credenciales de S3 y subidas
 * de ficheros de decenas de MB en el camino crítico de la
 * autenticación. Un fallo aquí no debe poder tumbar el login.
 */
@RestController
public class ReenvioController {

    private static final Logger log = LoggerFactory.getLogger(ReenvioController.class);

    private final TransformadorMultipart transformador;
    private final RestClient http;
    private final String catalogoBaseUrl;

    public ReenvioController(TransformadorMultipart transformador,
                             @Value("${files.catalog-base-url}") String catalogoBaseUrl) {
        this.transformador = transformador;
        this.catalogoBaseUrl = catalogoBaseUrl.replaceAll("/+$", "");
        this.http = RestClient.builder().build();
    }

    @PostMapping(value = "/files/**", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    public ResponseEntity<String> post(MultipartHttpServletRequest peticion,
                                       @RequestHeader(HttpHeaders.AUTHORIZATION) String autorizacion) {
        return reenviar("POST", peticion, autorizacion);
    }

    @PutMapping(value = "/files/**", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    public ResponseEntity<String> put(MultipartHttpServletRequest peticion,
                                      @RequestHeader(HttpHeaders.AUTHORIZATION) String autorizacion) {
        return reenviar("PUT", peticion, autorizacion);
    }

    private ResponseEntity<String> reenviar(String metodo,
                                            MultipartHttpServletRequest peticion,
                                            String autorizacion) {
        String destino = catalogoBaseUrl + rutaDestino(peticion);

        Map<String, String> campos = new LinkedHashMap<>();
        peticion.getParameterMap().forEach((k, v) -> {
            if (v != null && v.length > 0) {
                campos.put(k, v[0]);
            }
        });

        Map<String, List<MultipartFile>> ficheros = new LinkedHashMap<>();
        peticion.getMultiFileMap().forEach((campo, partes) ->
                ficheros.put(campo, new ArrayList<>(partes)));

        Map<String, Object> cuerpo =
                transformador.transformar(campos, ficheros, usuarioDe(autorizacion));

        log.info("{} {} — {} campo(s), {} con fichero", metodo, destino,
                campos.size(), ficheros.size());

        // El JWT del cliente se reenvía TAL CUAL, no se usa una
        // identidad de servicio. Si este servicio llamara con
        // credenciales propias, el :CONTEXT.USER_ID que recibe el
        // procedimiento sería el del file-service y toda la auditoría
        // quedaría inservible — ese campo existe justamente para que el
        // procedimiento reciba la identidad verificada de quien pidió
        // la operación.
        var solicitud = http.method(org.springframework.http.HttpMethod.valueOf(metodo))
                .uri(destino)
                .header(HttpHeaders.AUTHORIZATION, autorizacion)
                .contentType(MediaType.APPLICATION_JSON)
                .body(cuerpo);

        return solicitud.retrieve()
                .onStatus(estado -> true, (req, res) -> { /* se propaga tal cual */ })
                .toEntity(String.class);
    }

    /**
     * {@code /files/eval-col/funcionario} → {@code /eval-col/funcionario}.
     *
     * <p>El prefijo {@code /files} sólo sirve para que el gateway sepa
     * enrutar aquí; el catálogo no lo conoce.
     */
    static String rutaDestino(HttpServletRequest peticion) {
        String ruta = (String) peticion.getAttribute(
                org.springframework.web.servlet.HandlerMapping.PATH_WITHIN_HANDLER_MAPPING_ATTRIBUTE);
        if (ruta == null || ruta.isBlank()) {
            ruta = peticion.getRequestURI();
        }
        if (ruta.startsWith("/files")) {
            ruta = ruta.substring("/files".length());
        }
        if (ruta.isBlank() || "/".equals(ruta)) {
            throw new ResponseStatusException(
                    org.springframework.http.HttpStatus.BAD_REQUEST,
                    "Falta la ruta del catálogo: usa /files/<microservicio>/<ruta>");
        }
        return ruta;
    }

    /**
     * Sólo para la columna {@code created_by} de TARCHIVO. La identidad
     * que de verdad importa —la que audita el procedimiento— viaja en
     * el JWT que se reenvía, verificada por el gateway.
     */
    private static String usuarioDe(String autorizacion) {
        try {
            String jwt = autorizacion.substring("Bearer ".length());
            String carga = jwt.split("\\.")[1];
            String json = new String(java.util.Base64.getUrlDecoder().decode(carga),
                    java.nio.charset.StandardCharsets.UTF_8);
            var m = java.util.regex.Pattern.compile("\"sub\"\\s*:\\s*\"([^\"]+)\"").matcher(json);
            return m.find() ? m.group(1) : "desconocido";
        } catch (RuntimeException e) {
            return "desconocido";
        }
    }
}
