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
            String cuerpo = e.getResponseBodyAsString();
            log.warn("query-service respondio {} para {}: {}", e.getStatusCode(), path, cuerpo);
            // En un 4xx el problema es lo que mando el llamante, y el mensaje
            // del query-service dice EXACTAMENTE cual es ("el elemento [0] es
            // String, esperado Long"). Tragarselo obliga a entrar al servidor a
            // leer logs para diagnosticar un error del front; propagarlo lo deja
            // visible en la pestaña Network. Los 5xx si se generalizan: ahi el
            // detalle es interno y no le sirve a nadie del otro lado.
            String motivo = e.getStatusCode().is4xxClientError()
                    ? mensajeDe(cuerpo)
                    : "No se pudieron obtener los datos del reporte.";
            throw new ResponseStatusException(e.getStatusCode(), motivo);
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
