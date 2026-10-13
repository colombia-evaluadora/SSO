package com.co.eurekatic.ssoadmin.client;

import org.springframework.http.client.JdkClientHttpRequestFactory;

import java.net.http.HttpClient;
import java.time.Duration;

/** Fabrica de {@link JdkClientHttpRequestFactory} con timeouts de conexion y lectura. */
public final class HttpTimeouts {

    private HttpTimeouts() {}

    public static JdkClientHttpRequestFactory factory(Duration connect, Duration read) {
        HttpClient http = HttpClient.newBuilder().connectTimeout(connect).build();
        JdkClientHttpRequestFactory factory = new JdkClientHttpRequestFactory(http);
        factory.setReadTimeout(read);
        return factory;
    }
}
