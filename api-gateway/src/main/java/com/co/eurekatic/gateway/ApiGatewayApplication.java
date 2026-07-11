package com.co.eurekatic.gateway;

import com.co.eurekatic.common.security.JwtProperties;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.boot.hibernate.autoconfigure.HibernateJpaAutoConfiguration;
import org.springframework.boot.jdbc.autoconfigure.DataSourceAutoConfiguration;
import org.springframework.boot.jdbc.autoconfigure.DataSourceTransactionManagerAutoConfiguration;
import org.springframework.cloud.client.discovery.EnableDiscoveryClient;

/**
 * Entry point for the reactive api-gateway. Pulls JWT primitives
 * (the {@link JwtProperties} record) from the {@code common} module
 * via {@code @EnableConfigurationProperties}.
 *
 * <p>The gateway does NOT need JPA — it just routes and validates
 * JWTs. We exclude the JPA / DataSource auto-configurations so the
 * gateway doesn't try to wire up a HikariCP pool against a database
 * that doesn't exist. The {@code common} module pulls in
 * {@code spring-data-jpa}, but that is a transitive dep we can
 * ignore at the auto-config layer.
 *
 * <p><b>Spring Boot 4 migration:</b> the per-stack split moved
 * these auto-configuration classes out of the monolithic
 * {@code spring-boot-autoconfigure} jar:
 * <ul>
 *   <li>{@code DataSourceAutoConfiguration} and
 *       {@code DataSourceTransactionManagerAutoConfiguration} now
 *       live in {@code spring-boot-jdbc} under
 *       {@code org.springframework.boot.jdbc.autoconfigure}.</li>
 *   <li>{@code HibernateJpaAutoConfiguration} moved to
 *       {@code spring-boot-hibernate} under
 *       {@code org.springframework.boot.hibernate.autoconfigure}.</li>
 * </ul>
 * The class names themselves are unchanged.
 */
@SpringBootApplication(scanBasePackages = {
        "com.co.eurekatic.gateway",
        "com.co.eurekatic.common.security"
}, exclude = {
        DataSourceAutoConfiguration.class,
        DataSourceTransactionManagerAutoConfiguration.class,
        HibernateJpaAutoConfiguration.class
})
@EnableDiscoveryClient
@EnableConfigurationProperties(JwtProperties.class)
public class ApiGatewayApplication {

    public static void main(String[] args) {
        SpringApplication.run(ApiGatewayApplication.class, args);
    }
}
