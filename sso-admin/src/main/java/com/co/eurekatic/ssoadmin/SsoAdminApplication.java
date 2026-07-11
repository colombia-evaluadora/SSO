package com.co.eurekatic.ssoadmin;

import com.co.eurekatic.common.security.JwtProperties;
import com.co.eurekatic.ssoadmin.provisioner.ProvisionerClientConfig;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.boot.persistence.autoconfigure.EntityScan;
import org.springframework.cloud.client.discovery.EnableDiscoveryClient;
import org.springframework.context.annotation.ComponentScan;
import org.springframework.data.jpa.repository.config.EnableJpaRepositories;

/**
 * Entry point for sso-admin. Servlet (Tomcat) module registered
 * with Eureka, serving the user/role/group admin surface.
 *
 * <p>Port: 8083 (configurable via PORT env var). Behind the
 * api-gateway, the path prefix is {@code /sso-admin/**} and the
 * gateway strips it before forwarding — so the controller
 * endpoints use the legacy paths directly (e.g. {@code POST
 * /createAccount}).
 *
 * <p>The {@code common} module's entities, repositories, and JWT
 * service live outside this app's default base package, so
 * {@code ComponentScan}, {@code EntityScan}, and
 * {@code EnableJpaRepositories} all have to point at the right
 * packages explicitly — same pattern as auth-center.
 *
 * <p><b>Spring Boot 4 migration:</b> {@code EntityScan} moved
 * from {@code org.springframework.boot.autoconfigure.domain} to
 * {@code org.springframework.boot.persistence.autoconfigure}
 * (Boot 4's per-stack split moved JPA-adjacent code out of the
 * monolithic {@code spring-boot-autoconfigure} jar into
 * {@code spring-boot-persistence}). The annotation itself is
 * unchanged.
 */
@SpringBootApplication
@EnableDiscoveryClient
@ComponentScan(basePackages = {
        "com.co.eurekatic.ssoadmin",
        "com.co.eurekatic.common.entity",
        "com.co.eurekatic.common.repository",
        "com.co.eurekatic.common.security"
})
@EntityScan(basePackages = "com.co.eurekatic.common.entity")
@EnableJpaRepositories(basePackages = "com.co.eurekatic.common.repository")
@EnableConfigurationProperties({JwtProperties.class, ProvisionerClientConfig.class})
public class SsoAdminApplication {

    public static void main(String[] args) {
        SpringApplication.run(SsoAdminApplication.class, args);
    }
}
