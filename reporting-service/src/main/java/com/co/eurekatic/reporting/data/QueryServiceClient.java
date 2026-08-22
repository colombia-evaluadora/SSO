package com.co.eurekatic.reporting.data;

import com.co.eurekatic.reporting.config.ReportingProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.client.ClientHttpRequestFactory;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;
import org.springframework.web.server.ResponseStatusException;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;

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

    private final RestClient client;

    public QueryServiceClient(ReportingProperties props) {
        String baseUrl = Objects.requireNonNull(
                props.getQueryServiceBaseUrl(),
                "reporting.query-service-base-url es obligatorio");

        // Timeouts explicitos: el default de la fabrica simple es "sin
        // limite", y una consulta sin paginar que se cuelgue dejaria el
        // hilo del reporte tomado para siempre.
        SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
        factory.setConnectTimeout((int) java.time.Duration.ofSeconds(10).toMillis());
        factory.setReadTimeout((int) props.getRequestTimeout().toMillis());

        this.client = RestClient.builder()
                .baseUrl(baseUrl)
                .requestFactory((ClientHttpRequestFactory) factory)
                .defaultHeader(HttpHeaders.ACCEPT, MediaType.APPLICATION_JSON_VALUE)
                .build();
    }

    /**
     * Pide las filas de un endpoint sin paginar.
     *
     * @param path       ruta registrada en {@code public.query} (V67)
     * @param bearer     token del usuario, tal cual llego
     * @param filters    filtros elegidos en pantalla; puede venir vacio,
     *                   y vacio significa "sin filtrar" (o sea: todo)
     * @param sorting    orden elegido en pantalla; puede ser null
     */
    public List<Map<String, Object>> fetchRows(String path,
                                               String bearer,
                                               Map<String, Object> filters,
                                               Map<String, Object> sorting) {

        // El cuerpo replica el del listado menos pageIndex/pageSize. Los
        // filtros ausentes NO se rellenan con nada: llegan como NULL al
        // SQL y la funcion los ignora, que es como se obtiene "sin
        // filtro = todo" sin escribir una sola rama para ese caso.
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("filters", filters == null ? Map.of() : filters);
        if (sorting != null && !sorting.isEmpty()) {
            body.put("sorting", sorting);
        }

        Map<String, Object> response;
        try {
            response = client.post()
                    .uri(path)
                    .header(HttpHeaders.AUTHORIZATION, "Bearer " + bearer)
                    .contentType(MediaType.APPLICATION_JSON)
                    .body(body)
                    .retrieve()
                    .body(new org.springframework.core.ParameterizedTypeReference<>() {});
        } catch (org.springframework.web.client.HttpStatusCodeException e) {
            // Se propaga el codigo del query-service en vez de traducir
            // todo a 500: un 403 por rol o un 400 por un filtro invalido
            // son respuestas del usuario, no fallas del reporte.
            log.warn("query-service respondio {} para {}: {}",
                    e.getStatusCode(), path, e.getResponseBodyAsString());
            throw new ResponseStatusException(e.getStatusCode(),
                    "No se pudieron obtener los datos del reporte.");
        } catch (RestClientException e) {
            log.error("Fallo la llamada al query-service para {}", path, e);
            throw new ResponseStatusException(HttpStatus.BAD_GATEWAY,
                    "El servicio de datos no respondio.");
        }

        if (response == null) {
            return List.of();
        }

        // El controlador de rutas del query-service siempre responde con
        // el sobre {rows, outParams?}.
        Object rows = response.get("rows");
        if (rows instanceof List<?> list) {
            @SuppressWarnings("unchecked")
            List<Map<String, Object>> typed = (List<Map<String, Object>>) list;
            return typed;
        }
        log.warn("Respuesta sin 'rows' desde {}: claves={}", path, response.keySet());
        return List.of();
    }
}
