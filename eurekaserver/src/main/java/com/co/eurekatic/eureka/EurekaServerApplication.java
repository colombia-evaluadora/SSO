package com.co.eurekatic.eureka;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.cloud.netflix.eureka.server.EnableEurekaServer;

/**
 * Entry point for the Eureka service registry.
 *
 * <p>Step 1 of the modernization plan: this module exists only to prove
 * Spring Boot 3.5.14 + Spring Cloud 2025.0.2.1 work together. No
 * authentication, no business endpoints, no JWT — just a runnable
 * registry on port 8761.
 */
@SpringBootApplication
@EnableEurekaServer
public class EurekaServerApplication {

    public static void main(String[] args) {
        SpringApplication.run(EurekaServerApplication.class, args);
    }
}
