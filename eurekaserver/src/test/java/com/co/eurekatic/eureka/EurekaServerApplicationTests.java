package com.co.eurekatic.eureka;

import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.TestPropertySource;

/**
 * Smoke test — proves the Spring context (with @EnableEurekaServer) wires up
 * without errors. Does not start a real Eureka peer or perform HTTP probes;
 * end-to-end HTTP verification is done outside of tests in step 1.
 */
@SpringBootTest
@TestPropertySource(properties = {
        "eureka.client.register-with-eureka=false",
        "eureka.client.fetch-registry=false"
})
class EurekaServerApplicationTests {

    @Test
    void contextLoads() {
    }
}
