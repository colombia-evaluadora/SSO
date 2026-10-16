package com.co.eurekatic.scheduler.accion;

import java.net.URI;
import java.net.http.HttpClient;
import java.time.Duration;
import org.springframework.http.HttpMethod;
import org.springframework.http.client.JdkClientHttpRequestFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;

/**
 * Llama a un endpoint HTTP. Una respuesta que no sea 2xx es un fallo.
 * Los secretos de las cabeceras se pasan con placeholders
 * ({@code ${TOKEN_X}}), nunca literales.
 *
 * <pre>
 * parametros:
 *   url: http://notification-service:8080/algo
 *   metodo: POST                # opcional, por defecto GET
 *   cabeceras:
 *     Authorization: Bearer ${TOKEN_X}
 *   cuerpo: '{"a":1}'           # opcional
 *   timeout: 30s                # opcional, por defecto 30s
 * </pre>
 */
@Component
public class AccionHttp implements Accion {

    private static final Duration TIMEOUT_POR_DEFECTO = Duration.ofSeconds(30);

    private final RestClient.Builder builder;
    private final HttpClient httpClient = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(10))
            .build();

    public AccionHttp(RestClient.Builder builder) {
        this.builder = builder;
    }

    @Override
    public String tipo() {
        return "http";
    }

    @Override
    public void validar(Parametros parametros) {
        URI.create(parametros.requerido("url"));
        HttpMethod.valueOf(parametros.texto("metodo", "GET").toUpperCase());
        parametros.duracion("timeout", TIMEOUT_POR_DEFECTO);
        parametros.mapa("cabeceras");
    }

    @Override
    public void ejecutar(String tareaId, Parametros parametros) {
        JdkClientHttpRequestFactory fabrica = new JdkClientHttpRequestFactory(httpClient);
        fabrica.setReadTimeout(parametros.duracion("timeout", TIMEOUT_POR_DEFECTO));

        RestClient.RequestBodySpec peticion = builder.clone()
                .requestFactory(fabrica)
                .build()
                .method(HttpMethod.valueOf(parametros.texto("metodo", "GET").toUpperCase()))
                .uri(URI.create(parametros.requerido("url")))
                .header("X-Scheduler-Tarea", tareaId)
                .headers(h -> parametros.mapa("cabeceras").forEach(h::set));

        String cuerpo = parametros.texto("cuerpo", null);
        if (cuerpo != null) {
            peticion.body(cuerpo);
        }
        peticion.retrieve().toBodilessEntity();
    }
}
