package com.co.eurekatic.aicontrol.client;

import com.co.eurekatic.aicontrol.config.ia.AiProperties;
import com.sun.net.httpserver.HttpServer;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpMethod;
import org.springframework.web.client.RestClient;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/** Contra un servidor HTTP real del JDK: comprueba la peticion que sale, no una simulacion. */
class QueryServiceClientInvocarTest {

    private HttpServer servidor;
    private final List<String> recibidas = new ArrayList<>();
    private int status = 200;
    private String respuesta = "{\"rows\":[{\"id\":1}]}";

    @BeforeEach
    void arrancar() throws IOException {
        servidor = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        servidor.createContext("/", intercambio -> {
            String cuerpo = new String(intercambio.getRequestBody().readAllBytes(), StandardCharsets.UTF_8);
            recibidas.add(intercambio.getRequestMethod() + " " + intercambio.getRequestURI().getRawPath()
                    + "?" + intercambio.getRequestURI().getRawQuery()
                    + " auth=" + intercambio.getRequestHeaders().getFirst("Authorization")
                    + " tipo=" + intercambio.getRequestHeaders().getFirst("Content-Type")
                    + " body=" + cuerpo);
            byte[] bytes = respuesta.getBytes(StandardCharsets.UTF_8);
            intercambio.getResponseHeaders().add("Content-Type", "application/json");
            intercambio.sendResponseHeaders(status, bytes.length);
            try (OutputStream salida = intercambio.getResponseBody()) {
                salida.write(bytes);
            }
        });
        servidor.start();
    }

    @AfterEach
    void parar() {
        servidor.stop(0);
    }

    private QueryServiceClient cliente() {
        String base = "http://127.0.0.1:" + servidor.getAddress().getPort() + "/";
        AiProperties props = new AiProperties(base, Duration.ofSeconds(5), "", 250, "v1", Duration.ofDays(7),
                35, Duration.ofSeconds(20), 4, 50f, Duration.ofSeconds(60));
        return new QueryServiceClient(props, RestClient.builder());
    }

    @Test
    void getEnviaQueryCodificadaYElTokenDelUsuario() {
        RespuestaQuery r = cliente().invocar(HttpMethod.GET, "/usuarios/permisos-menu",
                Map.of("NOMBRE", "a b&c"), Map.of(), "tkn");

        assertThat(r).isEqualTo(new RespuestaQuery.Exito(List.of(Map.of("id", 1))));
        assertThat(recibidas).hasSize(1);
        assertThat(recibidas.get(0)).startsWith("GET /usuarios/permisos-menu?NOMBRE=a%20b%26c")
                .contains("auth=Bearer tkn")
                .endsWith("body=");
    }

    @Test
    void postEnviaElCuerpoAnidadoComoJson() {
        status = 200;
        cliente().invocar(HttpMethod.POST, "/planeador/actividades", Map.of(),
                Map.of("PERSON", Map.of("EMAIL", "a@b.co")), "tkn");

        assertThat(recibidas.get(0)).startsWith("POST /planeador/actividades")
                .contains("\"PERSON\"").contains("\"EMAIL\"");
    }

    @Test
    void unPostSinArgumentosEnviaUnObjetoJsonVacio() {
        cliente().invocar(HttpMethod.POST, "/periodos-academicos/query", Map.of(), Map.of(), "tkn");

        assertThat(recibidas.get(0)).contains("tipo=application/json").endsWith("body={}");
    }

    @Test
    void unPatchLlegaComoPatchConSuCuerpo() {
        RespuestaQuery r = cliente().invocar(HttpMethod.PATCH, "/establecimientos/funcionarios/7", Map.of(),
                Map.of("PERSON", Map.of("PHONE", "3109876543")), "tkn");

        assertThat(r).isInstanceOf(RespuestaQuery.Exito.class);
        assertThat(recibidas.get(0)).startsWith("PATCH /establecimientos/funcionarios/7").contains("3109876543");
    }

    @Test
    void un4xxSeDevuelveConSuMensajeYUn5xxSinDetalle() {
        status = 403;
        respuesta = "{\"message\":\"Sin permiso para editar\"}";
        assertThat(cliente().invocar(HttpMethod.GET, "/x", Map.of(), Map.of(), "tkn"))
                .isEqualTo(new RespuestaQuery.ErrorCliente(403, "Sin permiso para editar"));

        status = 500;
        respuesta = "{\"message\":\"detalle interno de la base\"}";
        assertThat(cliente().invocar(HttpMethod.GET, "/x", Map.of(), Map.of(), "tkn"))
                .isInstanceOf(RespuestaQuery.ErrorServidor.class);
    }

    @Test
    void unServicioCaidoEsErrorDeServidor() throws IOException {
        int puerto = servidor.getAddress().getPort();
        servidor.stop(0);
        AiProperties props = new AiProperties("http://127.0.0.1:" + puerto, Duration.ofSeconds(2), "", 250, "v1",
                Duration.ofDays(7), 35, Duration.ofSeconds(20), 4, 50f, Duration.ofSeconds(60));

        RespuestaQuery r = new QueryServiceClient(props, RestClient.builder())
                .invocar(HttpMethod.GET, "/x", Map.of(), Map.of(), "tkn");

        assertThat(r).isInstanceOf(RespuestaQuery.ErrorServidor.class);
    }
}
