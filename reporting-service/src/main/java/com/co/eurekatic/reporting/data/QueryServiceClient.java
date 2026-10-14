package com.co.eurekatic.reporting.data;

import com.co.eurekatic.reporting.config.ReportingProperties;
import org.slf4j.Logger;
import tools.jackson.core.JacksonException;
import tools.jackson.core.JsonParser;
import tools.jackson.core.JsonToken;
import tools.jackson.core.type.TypeReference;
import tools.jackson.databind.ObjectMapper;
import tools.jackson.databind.json.JsonMapper;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.HttpStatusCode;
import org.springframework.http.MediaType;
import org.springframework.http.client.ClientHttpRequestFactory;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;
import org.springframework.web.server.ResponseStatusException;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Cliente HTTP contra el query-service.
 *
 * <p>Es el unico punto por el que este servicio obtiene datos: no tiene
 * DataSource ni driver JDBC. Esa restriccion es deliberada — mientras
 * las filas lleguen por aca, el reporte no puede ver mas de lo que ve
 * la pantalla, porque atraviesa exactamente los mismos dos controles:
 * los {@code role_query} del endpoint y el gate dentro de la funcion
 * PL/pgSQL.
 *
 * <p>El token que se reenvia es el del usuario que pidio el reporte, no
 * una credencial de servicio. Es lo que hace que
 * {@code :CONTEXT.USER_ID} del SQL resuelva a la persona correcta.
 */
@Component
public class QueryServiceClient {

    private static final Logger log = LoggerFactory.getLogger(QueryServiceClient.class);

    private static final String PERFIL_TIMEOUT_HEADER = "X-Query-Timeout-Profile";
    private static final String PERFIL_TIMEOUT_REPORT = "report";

    private static final ObjectMapper MAPPER = JsonMapper.builder().build();
    private static final TypeReference<Map<String, Object>> FILA = new TypeReference<>() {};

    /** Base por defecto: la instancia del catalogo academico (eval-col). */
    private final String baseUrlPorDefecto;

    private final java.time.Duration requestTimeout;

    /**
     * Un RestClient por instancia de query-service, creado la primera vez
     * que se pide esa base y reusado despues.
     *
     * <p>Se construye uno por base en vez de pasar una URL absoluta a
     * {@code .uri(...)} para que la base quede fijada en el cliente: asi el
     * {@code path} de la definicion del reporte no puede, por venir mal
     * escrito en el yml, apuntar a un host arbitrario.
     */
    private final Map<String, RestClient> clientes = new ConcurrentHashMap<>();

    public QueryServiceClient(ReportingProperties props) {
        this.baseUrlPorDefecto = Objects.requireNonNull(
                props.getQueryServiceBaseUrl(),
                "reporting.query-service-base-url es obligatorio");
        this.requestTimeout = props.getRequestTimeout();
    }

    private RestClient clientePara(String baseUrl) {
        String base = (baseUrl == null || baseUrl.isBlank()) ? baseUrlPorDefecto : baseUrl;
        return clientes.computeIfAbsent(base, b -> {
            // Timeouts explicitos: el default de la fabrica simple es "sin
            // limite", y una consulta sin paginar que se cuelgue dejaria el
            // hilo del reporte tomado para siempre.
            SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
            factory.setConnectTimeout((int) java.time.Duration.ofSeconds(10).toMillis());
            factory.setReadTimeout((int) requestTimeout.toMillis());

            return RestClient.builder()
                    .baseUrl(b)
                    .requestFactory((ClientHttpRequestFactory) factory)
                    .defaultHeader(HttpHeaders.ACCEPT, MediaType.APPLICATION_JSON_VALUE)
                    // Pide a query-service el timeout largo de reportes (no el de listados).
                    .defaultHeader(PERFIL_TIMEOUT_HEADER, PERFIL_TIMEOUT_REPORT)
                    .build();
        });
    }

    /**
     * Saca el `message` del cuerpo de error del query-service. Si no viene o
     * no es JSON, cae a un texto generico — un error sin mensaje es peor que
     * uno impreciso.
     */
    private String mensajeDe(String cuerpo) {
        if (cuerpo == null || cuerpo.isBlank()) {
            return "No se pudieron obtener los datos del reporte.";
        }
        int i = cuerpo.indexOf("\"message\"");
        if (i < 0) {
            return "No se pudieron obtener los datos del reporte.";
        }
        int desde = cuerpo.indexOf(34, cuerpo.indexOf(58, i) + 1);
        int hasta = desde < 0 ? -1 : cuerpo.indexOf(34, desde + 1);
        return desde < 0 || hasta < 0
                ? "No se pudieron obtener los datos del reporte."
                : cuerpo.substring(desde + 1, hasta);
    }

    /**
     * Pide las filas de un endpoint sin paginar.
     *
     * @param baseUrl    instancia de query-service donde vive {@code path};
     *                   null o vacio = la instancia por defecto
     * @param path       ruta registrada en {@code public.query} (V67)
     * @param bearer     token del usuario, tal cual llego
     * @param filters    filtros elegidos en pantalla; puede venir vacio,
     *                   y vacio significa "sin filtrar" (o sea: todo)
     * @param sorting    orden elegido en pantalla; puede ser null
     * @param maxRows    tope de filas; al leer la fila maxRows+1 se corta con 422
     */
    public List<Map<String, Object>> fetchRows(String baseUrl,
                                               String path,
                                               String bearer,
                                               Map<String, Object> filters,
                                               Map<String, Object> sorting,
                                               int maxRows) {

        // El cuerpo replica el del listado menos pageIndex/pageSize. Los
        // filtros ausentes NO se rellenan con nada: llegan como NULL al
        // SQL y la funcion los ignora, que es como se obtiene "sin
        // filtro = todo" sin escribir una sola rama para ese caso.
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("filters", filters == null ? Map.of() : filters);
        if (sorting != null && !sorting.isEmpty()) {
            body.put("sorting", sorting);
        }

        try {
            return clientePara(baseUrl).post()
                    .uri(path)
                    .header(HttpHeaders.AUTHORIZATION, "Bearer " + bearer)
                    .contentType(MediaType.APPLICATION_JSON)
                    .body(body)
                    .exchange((req, res) -> {
                        if (res.getStatusCode().isError()) {
                            throw errorHttp(res.getStatusCode(), path,
                                    new String(res.getBody().readAllBytes(), StandardCharsets.UTF_8));
                        }
                        try (InputStream in = res.getBody()) {
                            return leerFilas(in, path, maxRows);
                        }
                    });
        } catch (RestClientException e) {
            log.error("Fallo la llamada al query-service para {}", path, e);
            throw new ResponseStatusException(HttpStatus.BAD_GATEWAY,
                    "El servicio de datos no respondio.");
        }
    }

    /**
     * POST de un cuerpo arbitrario a una ruta del catalogo, con el token del
     * usuario. Para los endpoints que no son un listado de reporte (registrar
     * o revocar una emision de boletin), cuyos binds no van bajo FILTERS.
     */
    public List<Map<String, Object>> postRows(String baseUrl, String path, String bearer,
                                              Map<String, Object> body, int maxRows) {
        try {
            return clientePara(baseUrl).post()
                    .uri(path)
                    .header(HttpHeaders.AUTHORIZATION, "Bearer " + bearer)
                    .contentType(MediaType.APPLICATION_JSON)
                    .body(body == null ? Map.of() : body)
                    .exchange((req, res) -> {
                        if (res.getStatusCode().isError()) {
                            throw errorHttp(res.getStatusCode(), path,
                                    new String(res.getBody().readAllBytes(), StandardCharsets.UTF_8));
                        }
                        try (InputStream in = res.getBody()) {
                            return leerFilas(in, path, maxRows);
                        }
                    });
        } catch (RestClientException e) {
            log.error("Fallo la llamada al query-service para {}", path, e);
            throw new ResponseStatusException(HttpStatus.BAD_GATEWAY,
                    "El servicio de datos no respondio.");
        }
    }

    /**
     * Ejecuta una consulta PUBLICA ({@code public_end}) por uuid, SIN token:
     * {@code POST /public/service}. Solo la usa la verificacion del boletin,
     * cuyas funciones toman unicamente el codigo del QR (y los 4 digitos), asi
     * que no hay identidad de usuario que reenviar. La respuesta es la lista
     * de filas sin sobre.
     */
    public List<Map<String, Object>> publicRows(String baseUrl, String uuid,
                                                Map<String, Object> params, int maxRows) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("uuid", uuid);
        body.put("params", params == null ? Map.of() : params);
        try {
            return clientePara(baseUrl).post()
                    .uri("/public/service")
                    .contentType(MediaType.APPLICATION_JSON)
                    .body(body)
                    .exchange((req, res) -> {
                        if (res.getStatusCode().isError()) {
                            throw errorHttp(res.getStatusCode(), uuid,
                                    new String(res.getBody().readAllBytes(), StandardCharsets.UTF_8));
                        }
                        try (InputStream in = res.getBody()) {
                            return leerLista(in, uuid, maxRows);
                        }
                    });
        } catch (RestClientException e) {
            log.error("Fallo la consulta publica {} al query-service", uuid, e);
            throw new ResponseStatusException(HttpStatus.BAD_GATEWAY,
                    "El servicio de datos no respondio.");
        }
    }

    /** Lee una lista JSON de filas (la forma de /public/service). */
    List<Map<String, Object>> leerLista(InputStream in, String origen, int maxRows) {
        List<Map<String, Object>> filas = new ArrayList<>();
        try (JsonParser p = MAPPER.createParser(in)) {
            if (p.nextToken() != JsonToken.START_ARRAY) {
                log.warn("Respuesta inesperada (no es una lista) desde {}", origen);
                return List.of();
            }
            while (p.nextToken() != JsonToken.END_ARRAY) {
                if (filas.size() >= maxRows) {
                    throw new ResponseStatusException(HttpStatus.UNPROCESSABLE_ENTITY,
                            "La consulta devolvio mas de " + maxRows + " registros.");
                }
                filas.add(p.readValueAs(FILA));
            }
            return filas;
        } catch (JacksonException e) {
            log.error("Respuesta ilegible del query-service para {}", origen, e);
            throw new ResponseStatusException(HttpStatus.BAD_GATEWAY,
                    "El servicio de datos respondio algo ilegible.");
        }
    }

    /**
     * Se propaga el codigo del query-service en vez de traducir todo a 500:
     * un 403 por rol o un 400 por un filtro invalido son respuestas del
     * usuario, no fallas del reporte. En un 4xx el mensaje del query-service
     * dice exactamente cual es el problema; los 5xx se generalizan.
     */
    private ResponseStatusException errorHttp(HttpStatusCode status, String path, String cuerpo) {
        log.warn("query-service respondio {} para {}: {}", status, path, cuerpo);
        String motivo = status.is4xxClientError()
                ? mensajeDe(cuerpo)
                : "No se pudieron obtener los datos del reporte.";
        return new ResponseStatusException(status, motivo);
    }

    /**
     * Lee el sobre {@code {rows:[...], outParams?}} en streaming: materializa
     * fila a fila y, al llegar a la fila maxRows+1, corta sin leer el resto.
     */
    List<Map<String, Object>> leerFilas(InputStream in, String path, int maxRows) {
        List<Map<String, Object>> filas = new ArrayList<>();
        try (JsonParser p = MAPPER.createParser(in)) {
            if (p.nextToken() != JsonToken.START_OBJECT) {
                log.warn("Respuesta inesperada (no es un objeto) desde {}", path);
                return List.of();
            }
            boolean conRows = false;
            while (p.nextToken() == JsonToken.PROPERTY_NAME) {
                String campo = p.currentName();
                JsonToken t = p.nextToken();
                if ("rows".equals(campo) && t == JsonToken.START_ARRAY) {
                    conRows = true;
                    while (p.nextToken() != JsonToken.END_ARRAY) {
                        if (filas.size() >= maxRows) {
                            // Fila maxRows+1: se deja de leer; el try cierra el stream.
                            throw new ResponseStatusException(HttpStatus.UNPROCESSABLE_ENTITY,
                                    "El reporte devolvio mas de " + maxRows
                                    + " registros y el maximo es " + maxRows
                                    + ". Agrega filtros para acotarlo.");
                        }
                        filas.add(p.readValueAs(FILA));
                    }
                } else {
                    p.skipChildren();
                }
            }
            if (!conRows) {
                log.warn("Respuesta sin 'rows' desde {}", path);
                return List.of();
            }
            return filas;
        } catch (JacksonException e) {
            log.error("Respuesta ilegible del query-service para {}", path, e);
            throw new ResponseStatusException(HttpStatus.BAD_GATEWAY,
                    "El servicio de datos respondio algo ilegible.");
        }
    }
}
