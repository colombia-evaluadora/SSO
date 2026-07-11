package com.co.eurekatic.notificationservice;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.persistence.autoconfigure.EntityScan;
import org.springframework.cloud.client.discovery.EnableDiscoveryClient;
import org.springframework.context.annotation.ComponentScan;
import org.springframework.data.jpa.repository.config.EnableJpaRepositories;
import org.springframework.scheduling.annotation.EnableScheduling;

/**
 * Entry point for notification-service.
 *
 * <p>The application is a Spring Boot 4.0 servlet app that:
 * <ul>
 *   <li>registers with Eureka ({@code @EnableDiscoveryClient}),</li>
 *   <li>consumes JSON envelopes from three RabbitMQ queues
 *       (sms / email / push) via {@code @RabbitListener},</li>
 *   <li>persists {@code notification_log} rows for idempotency
 *       and audit,</li>
 *   <li>re-renders templates and dispatches to the configured
 *       provider(s) with Resilience4j circuit breakers,</li>
 *   <li>refreshes its provider configuration every 30 s
 *       ({@code @EnableScheduling}) and exposes the effective
 *       config + breaker state via {@code /actuator/providers}.</li>
 * </ul>
 *
 * <p>This app owns its own minimal schema (no dependency on
 * {@code common}'s entities/repositories) and has its own
 * {@code repository}-ish subpackage (e.g.
 * {@code NotificationLogRepository} in {@code repository},
 * {@code ProviderConfigRepository} in {@code provider}), so
 * {@code EnableJpaRepositories} scans the whole module subtree
 * to catch both.
 *
 * <p><b>Spring Boot 4 migration:</b> {@code EntityScan} moved from
 * {@code org.springframework.boot.autoconfigure.domain} to
 * {@code org.springframework.boot.persistence.autoconfigure} as part
 * of the per-stack split in Boot 4.0.x. The class itself is
 * unchanged.
 */
@SpringBootApplication
@EnableDiscoveryClient
@EnableScheduling
@ComponentScan(basePackages = {
        "com.co.eurekatic.notificationservice"
})
@EntityScan(basePackages = {
        // NotificationLog lives in this module's `domain`
        // package; scanning the whole module subtree catches it
        // and any future entities without re-touching this list.
        // JpaRepository interfaces get filtered out automatically.
        // Deliberately does NOT include common.entity — this
        // service owns its own minimal schema (notification_log,
        // provider_config, via its own Flyway migrations under
        // db/migration) and never reads/writes the shared `sso`
        // entities. Scanning common.entity here made
        // ddl-auto=validate check those tables too, which don't
        // exist in this service's schema — fails startup in any
        // environment (e.g. tests) that doesn't also happen to
        // point at a fully-migrated `sso` database.
        "com.co.eurekatic.notificationservice"
})
@EnableJpaRepositories(basePackages = {
        // ProviderConfigRepository actually lives in the
        // `provider` subpackage, not a dedicated `repository`
        // one — scanning the whole module subtree catches both.
        "com.co.eurekatic.notificationservice"
})
public class NotificationServiceApplication {

    public static void main(String[] args) {
        SpringApplication.run(NotificationServiceApplication.class, args);
    }
}
