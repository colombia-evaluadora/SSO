package com.co.eurekatic.aicontrol.client;

import com.co.eurekatic.aicontrol.config.ia.AiProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.core.ParameterizedTypeReference;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.client.HttpStatusCodeException;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;
import org.springframework.web.server.ResponseStatusException;

import java.net.URI;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Collectors;

/**
 * Cliente del query-service: la unica via por la que este servicio lee o
 * escribe datos.
 *
 * <p>Se reenvia el token del usuario, no una credencial de servicio, para
 * que {@code :CONTEXT.USER_ID} resuelva a esa persona y el gate PL/pgSQL
 * decida igual que en la pantalla. Mismo patron que el cliente homonimo de
 * reporting-service.
 */
@Component
public class QueryServiceClient {

    private static final Logger log = LoggerFactory.getLogger(QueryServiceClient.class);
    private static final Pattern MESSAGE = Pattern.compile("\"message\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"");
    private static final String GENERICO = "No se pudieron obtener los datos del servicio academico.";

    private final RestClient rest;
    private final String base;

    public QueryServiceClient(AiProperties props, RestClient.Builder builder) {
        String url = Objects.requireNonNull(props.queryServiceBaseUrl(),
                "sso.ai.query-service-base-url es obligatorio");
        this.base = url.endsWith("/") ? url.substring(0, url.length() - 1) : url;
        // Timeouts explicitos: el default de la fabrica simple es "sin limite".
        SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
        factory.setConnectTimeout(Duration.ofSeconds(10));
        factory.setReadTimeout(props.requestTimeout());
        this.rest = builder
                .baseUrl(this.base)
                .requestFactory(factory)
                .defaultHeader(HttpHeaders.ACCEPT, MediaType.APPLICATION_JSON_VALUE)
                .build();
    }

    /**
     * POST a una ruta de {@code public.query} y devuelve sus filas.
     *
     * @param path   ruta registrada en {@code public.query}, sin prefijo de gateway
     * @param bearer token del usuario, sin el prefijo "Bearer "
     * @param body   binds {@code :BODY.*} de la fila
     */
    public List<Map<String, Object>> post(String path, String bearer, Map<String, Object> body) {
        Map<String, Object> response;
        try {
            response = rest.post()
                    .uri(path)
                    .header(HttpHeaders.AUTHORIZATION, "Bearer " + bearer)
                    .contentType(MediaType.APPLICATION_JSON)
                    .body(body)
                    .retrieve()
                    .body(new ParameterizedTypeReference<>() {});
        } catch (HttpStatusCodeException e) {
            // Se propaga el codigo del query-service: un 403 del gate, un 404
            // de matricula o un 400 "sin observaciones" son respuestas para el
            // usuario, no fallas de este servicio. En 4xx el mensaje del
            // query-service dice exactamente que paso; en 5xx es interno.
            String cuerpo = e.getResponseBodyAsString();
            log.warn("query-service respondio {} para {}", e.getStatusCode(), path);
            String motivo = e.getStatusCode().is4xxClientError() ? mensajeDe(cuerpo) : GENERICO;
            throw new ResponseStatusException(e.getStatusCode(), motivo);
        } catch (RestClientException e) {
            log.error("Fallo la llamada al query-service para {}", path, e);
            throw new ResponseStatusException(HttpStatus.BAD_GATEWAY, GENERICO);
        }

        if (response != null && response.get("rows") instanceof List<?> list) {
            @SuppressWarnings("unchecked")
            List<Map<String, Object>> rows = (List<Map<String, Object>>) list;
            return rows;
        }
        return List.of();
    }

    /**
     * Invoca una ruta de {@code public.query} con su verbo y sus binds. Los errores
     * vuelven como {@link RespuestaQuery} y no como excepcion: el invocador de
     * herramientas los traduce para el modelo.
     *
     * @param metodo       verbo HTTP de la ruta
     * @param rutaResuelta path sin prefijo de gateway, con los {@code PARAM} ya sustituidos
     *                     y codificados (lo hace {@code ConstructorPeticion})
     * @param query        binds {@code :QUERY.*}; los codifica este metodo
     * @param body         binds {@code :BODY.*} ya anidados; se ignora en GET y, vacio, viaja como {@code {}}
     * @param bearer       token del usuario, sin el prefijo "Bearer "
     */
    public RespuestaQuery invocar(HttpMethod metodo, String rutaResuelta, Map<String, String> query,
                                  Map<String, Object> body, String bearer) {
        URI uri;
        try {
            uri = URI.create(base + rutaResuelta + sufijoQuery(query));
        } catch (IllegalArgumentException e) {
            return new RespuestaQuery.ErrorCliente(HttpStatus.BAD_REQUEST.value(),
                    "La ruta pedida no es valida para el servicio academico.");
        }
        try {
            RestClient.RequestBodySpec spec = rest.method(metodo).uri(uri)
                    .header(HttpHeaders.AUTHORIZATION, "Bearer " + bearer);
            // Fuera de GET siempre va JSON, aunque sea {}: sin Content-Type el query-service responde 415.
            RestClient.RequestHeadersSpec<?> peticion = metodo == HttpMethod.GET
                    ? spec
                    : spec.contentType(MediaType.APPLICATION_JSON).body(body == null ? Map.of() : body);
            Map<String, Object> respuesta = peticion.retrieve().body(new ParameterizedTypeReference<>() {});
            return new RespuestaQuery.Exito(filasDe(respuesta));
        } catch (HttpStatusCodeException e) {
            log.warn("query-service respondio {} para {} {}", e.getStatusCode(), metodo, rutaResuelta);
            if (e.getStatusCode().is4xxClientError()) {
                return new RespuestaQuery.ErrorCliente(e.getStatusCode().value(),
                        mensajeDe(e.getResponseBodyAsString()));
            }
            return new RespuestaQuery.ErrorServidor();
        } catch (RestClientException e) {
            log.error("Fallo la llamada al query-service {} {}", metodo, rutaResuelta, e);
            return new RespuestaQuery.ErrorServidor();
        }
    }

    @SuppressWarnings("unchecked")
    private static List<Map<String, Object>> filasDe(Map<String, Object> respuesta) {
        if (respuesta != null && respuesta.get("rows") instanceof List<?> filas) {
            return (List<Map<String, Object>>) filas;
        }
        return List.of();
    }

    static String sufijoQuery(Map<String, String> query) {
        if (query == null || query.isEmpty()) {
            return "";
        }
        return query.entrySet().stream()
                .map(e -> codificar(e.getKey()) + "=" + codificar(e.getValue()))
                .collect(Collectors.joining("&", "?", ""));
    }

    private static String codificar(String valor) {
        return URLEncoder.encode(valor, StandardCharsets.UTF_8).replace("+", "%20");
    }

    static String mensajeDe(String cuerpo) {
        if (cuerpo == null) {
            return GENERICO;
        }
        Matcher m = MESSAGE.matcher(cuerpo);
        return m.find() ? m.group(1).replace("\\\"", "\"") : GENERICO;
    }
}
