package com.co.eurekatic.hello;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.cloud.client.discovery.EnableDiscoveryClient;
import org.springframework.context.annotation.ComponentScan;

/**
 * Reference downstream service. Demonstrates how a real business
 * service sits behind the gateway and consumes the
 * {@code X-Authenticated-*} headers that
 * {@code api-gateway}'s {@code UserForwardingGlobalFilter} injects.
 *
 * <p>This service is intentionally tiny — it exists to prove the
 * end-to-end flow works:
 *
 * <ol>
 *   <li>auth-center issues a JWT on login.</li>
 *   <li>api-gateway validates the JWT, populates the reactive
 *       {@code SecurityContext} with an {@code AuthPrincipal}, and
 *       injects {@code X-Authenticated-User} / {@code X-Authenticated-Roles}
 *       / {@code X-Authenticated-Token-Type} into the downstream
 *       request.</li>
 *   <li>This service reads those headers and returns a hello to the
 *       authenticated user.</li>
 * </ol>
 *
 * <p>No database: it depends only on common-jwt, common-openapi and
 * common-observability, so JPA and DataSource are not on the classpath.
 */
@SpringBootApplication
@EnableDiscoveryClient
@ComponentScan(basePackages = {
        "com.co.eurekatic.hello",
        "com.co.eurekatic.common.security"
})
public class HelloServiceApplication {

    public static void main(String[] args) {
        SpringApplication.run(HelloServiceApplication.class, args);
    }
}
