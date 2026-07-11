package com.co.eurekatic.provisioner;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.ConfigurationPropertiesScan;

/**
 * Provisioner sidecar entry point. Sole purpose: translate
 * an HTTP {@code POST /provision} from sso-admin into a
 * Docker Engine API call against the local unix socket,
 * and an {@code HTTP DELETE /provision/{name}} into a
 * container stop+remove.
 *
 * <p><b>Security boundary.</b> This is the ONLY container in
 * the stack that mounts {@code /var/run/docker.sock}. It
 * runs without authentication because the only caller
 * (sso-admin) reaches it over the internal docker-compose
 * network. In a prod deployment with a hostile network
 * surface this would need a TLS + token story, but inside
 * compose the docker network is private.
 *
 * <p>{@code @ConfigurationPropertiesScan} picks up
 * {@link ProvisionerProperties} (the docker image, network,
 * env vars) without an explicit
 * {@code @EnableConfigurationProperties} registration.
 */
@SpringBootApplication
@ConfigurationPropertiesScan(basePackages = "com.co.eurekatic.provisioner")
public class ProvisionerApplication {

    public static void main(String[] args) {
        SpringApplication.run(ProvisionerApplication.class, args);
    }
}