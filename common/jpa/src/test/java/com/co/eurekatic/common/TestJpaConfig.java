package com.co.eurekatic.common;

import org.springframework.boot.autoconfigure.EnableAutoConfiguration;
import org.springframework.boot.persistence.autoconfigure.EntityScan;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.jpa.repository.config.EnableJpaRepositories;

/**
 * Minimal Spring config for tests. The {@code common} module is a library
 * (no {@code @SpringBootApplication} of its own), so JPA tests must point
 * explicitly at this class via {@code @DataJpaTest(classes = ...)} or
 * {@code @ContextConfiguration(classes = ...)}.
 *
 * <p>It enables JPA auto-configuration, scans for entities and repositories
 * in this module, and lets Spring Boot provide the
 * {@code DataSource}/{@code EntityManagerFactory} beans.
 *
 * <p><b>Spring Boot 4 migration:</b> {@code EntityScan} moved from
 * {@code org.springframework.boot.autoconfigure.domain} to
 * {@code org.springframework.boot.persistence.autoconfigure} as part of
 * the per-stack split in Boot 4.0.x. The class itself is unchanged.
 */
@Configuration
@EntityScan(basePackages = "com.co.eurekatic.common.entity")
@EnableJpaRepositories(basePackages = "com.co.eurekatic.common.repository")
@EnableAutoConfiguration
public class TestJpaConfig {
}
