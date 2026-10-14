package com.co.eurekatic.gateway.health;

import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.test.web.reactive.server.WebTestClient;

class EvalColHealthControllerTest {

    private final WebTestClient client =
            WebTestClient.bindToController(new EvalColHealthController()).build();

    @Test
    void respondeJsonSinCacheConEstadoYHora() {
        client.get().uri("/api/eval-col/health").exchange()
                .expectStatus().isOk()
                .expectHeader().contentTypeCompatibleWith(MediaType.APPLICATION_JSON)
                .expectHeader().valueEquals("Cache-Control", "no-store")
                .expectBody()
                .jsonPath("$.status").isEqualTo("ok")
                .jsonPath("$.ts").isNumber()
                .jsonPath("$.length()").isEqualTo(2);
    }
}
