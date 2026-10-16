package com.co.eurekatic.gateway;

import com.co.eurekatic.common.security.JwtProperties;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.cloud.client.discovery.EnableDiscoveryClient;
import org.springframework.scheduling.annotation.EnableScheduling;

/**
 * Entry point for the reactive api-gateway. Pulls JWT primitives
 * (the {@link JwtProperties} record) from the {@code common} module
 * via {@code @EnableConfigurationProperties}.
 *
 * <p>The gateway does NOT need JPA — it just routes and validates
 * JWTs. It depends only on common-core, common-jwt and
 * common-observability, so neither JPA nor a DataSource is on the
 * classpath and nothing has to be excluded.
 */
@SpringBootApplication(scanBasePackages = {
        "com.co.eurekatic.gateway",
        "com.co.eurekatic.common.security"
})
@EnableDiscoveryClient
@EnableConfigurationProperties(JwtProperties.class)
@EnableScheduling
public class ApiGatewayApplication {

    public static void main(String[] args) {
        SpringApplication.run(ApiGatewayApplication.class, args);
    }
}
