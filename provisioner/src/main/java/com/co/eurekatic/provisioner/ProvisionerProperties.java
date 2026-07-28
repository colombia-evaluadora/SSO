package com.co.eurekatic.provisioner;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Provisioner settings bound from {@code docker.*} in
 * {@code application.yml}.
 *
 * <p>These are the knobs that change between dev (the
 * compose stack) and a hypothetical prod-with-Kubernetes
 * deployment. The defaults match the docker-compose service
 * block in {@code docker-compose.yml}.
 */
@ConfigurationProperties(prefix = "docker")
public class ProvisionerProperties {

    /** Image the provisioner starts when a query-service
     *  instance is requested. Must be pre-pulled on the
     *  docker host. */
    private String image = "eurekatic/query-service:1.0.0-SNAPSHOT";

    /** Network the new container is attached to. Must be
     *  the same network eureka / sso-admin live on, so the
     *  container can register its Eureka heartbeat via
     *  service-name DNS. */
    private String network = "modernize_default";

    /** Path inside THIS container where the host docker
     *  socket is bind-mounted (see docker-compose.yml). */
    private String socketPath = "/var/run/docker.sock";

    /** Image used to register with Eureka. Query-service
     *  uses spring.application.name which is rewritten by
     *  its InstanceNameResolver to
     *  {@code query-service-<instanceName>}. We pass that
     *  rewritten value via env. */
    private String eurekaUrl = "http://eurekaserver:8761/eureka";

    /** Clave PÚBLICA RSA (PEM) que el nuevo contenedor de
     *  query-service usa para verificar los Bearer token que
     *  emite auth-center. Con RS256 el provisioner ya no
     *  reparte material de firma: aunque se comprometa, lo
     *  único que filtra es una clave pública. Vacía por
     *  defecto — el operador la pasa explícitamente en el
     *  bloque de compose (DOCKER_JWT_PUBLIC_KEY). */
    private String jwtPublicKey = "";

    /** Path the provisioner polls to verify the new
     *  container came up. The 30s timeout gives the JVM
     *  + Eureka registration enough room. */
    private int readyTimeoutSeconds = 45;

    public String getImage() { return image; }
    public void setImage(String image) { this.image = image; }
    public String getNetwork() { return network; }
    public void setNetwork(String network) { this.network = network; }
    public String getSocketPath() { return socketPath; }
    public void setSocketPath(String socketPath) { this.socketPath = socketPath; }
    public String getEurekaUrl() { return eurekaUrl; }
    public void setEurekaUrl(String eurekaUrl) { this.eurekaUrl = eurekaUrl; }
    public String getJwtPublicKey() { return jwtPublicKey; }
    public void setJwtPublicKey(String jwtPublicKey) { this.jwtPublicKey = jwtPublicKey; }
    public int getReadyTimeoutSeconds() { return readyTimeoutSeconds; }
    public void setReadyTimeoutSeconds(int readyTimeoutSeconds) {
        this.readyTimeoutSeconds = readyTimeoutSeconds;
    }
}