package com.co.eurekatic.ssoadmin.provisioner;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Settings for the {@link HttpContainerProvisioner}
 * RestClient. Bound from {@code sso.provisioner.*}.
 *
 * <p>The provisioner sidecar is its own service in
 * {@code docker-compose.yml} — the URL defaults to the
 * in-network name so the override is only needed when
 * running sso-admin locally against a sidecar on the host.
 */
@ConfigurationProperties(prefix = "sso.provisioner")
public class ProvisionerClientConfig {

    /** Base URL of the provisioner sidecar. No trailing slash. */
    private String baseUrl = "http://provisioner:9000";

    public String getBaseUrl() { return baseUrl; }
    public void setBaseUrl(String baseUrl) { this.baseUrl = baseUrl; }
}