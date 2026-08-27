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

    /** OTLP HTTP endpoint que el nuevo contenedor de
     *  query-service usa para exportar trazas / métricas /
     *  logs al colector (Alloy, OTel Collector, etc.). Se
     *  inyecta tal cual como env var
     *  {@code OTEL_EXPORTER_OTLP_ENDPOINT} al crear el
     *  contenedor; el default apunta al Alloy del stack
     *  compose. Sin esta env var el query-service spawneado
     *  cae al default hardcodeado en su application.yml
     *  ({@code http://localhost:4318}), que NO resuelve al
     *  colector porque "localhost" dentro del contenedor es
     *  el propio contenedor, no el host ni la red compose. */
    private String otlpEndpoint = "http://alloy:4318";

    /** V30 — secreto compartido que el query-service spawneado usa
     *  para llamar a /internal/pathTemplates en sso-admin (lo envía
     *  como cabecera X-Internal-Token). Se inyecta al contenedor
     *  nuevo como {@code QUERY_CATALOG_INTERNAL_TOKEN}.
     *
     *  Vacío por defecto, igual que el resto de secretos: el
     *  operador lo pasa en el bloque de compose del provisioner.
     *  Sin él, el contenedor spawneado arranca y se registra en
     *  Eureka igual, pero su path-registry falla cerrado (503) y
     *  las rutas por plantilla de ese servicio nunca resuelven —
     *  una degradación silenciosa que sólo se ve en los logs de
     *  sso-admin como "Rejected GET /internal/... — missing
     *  X-Internal-Token header". */
    private String catalogInternalToken = "";

    /** Base URL que el query-service spawneado usa para resolver
     *  uuid→SQL y para cargar su path-registry. Se inyecta como
     *  {@code QUERY_CATALOG_BASE_URL}.
     *
     *  Apunta DIRECTAMENTE a sso-admin, no al api-gateway. La
     *  cadena de seguridad del gateway termina en
     *  {@code anyExchange().authenticated()}, así que rechaza
     *  {@code /sso-admin/internal/**} con 401 antes de que llegue
     *  a sso-admin: el {@code X-Internal-Token} no significa nada
     *  para el gateway, que espera un JWT. Y no es cuestión de
     *  añadir ese path al permitAll — el gateway es la superficie
     *  pública, y el surface /internal debe seguir siendo
     *  inalcanzable desde fuera de la red de docker.
     *
     *  Mismo criterio que {@code gateway.catalog-url}, que ya
     *  apunta a {@code http://sso-admin:8083}. */
    private String catalogBaseUrl = "http://sso-admin:8083";

    /** Path the provisioner polls to verify the new
     *  container came up. The 30s timeout gives the JVM
     *  + Eureka registration enough room. */
    private int readyTimeoutSeconds = 45;

    /** Host of the shared {@code sso-redis} instance. Se inyecta al
     *  contenedor de query-service spawneado como
     *  {@code REDIS_HOST} — sin esto el contenedor cae al default
     *  {@code localhost} de su propio application.yml, que dentro
     *  del contenedor resuelve al propio contenedor, no al
     *  {@code redis} de la red compose, y el {@code RedisCacheManager}
     *  arranca contra un Redis que no existe. */
    private String redisHost = "redis";

    /** Puerto del {@code sso-redis} compartido. Se inyecta como
     *  {@code REDIS_PORT}. */
    private String redisPort = "6379";

    /** Password del {@code sso-redis} compartido, si el operador
     *  configuró uno. Se inyecta como {@code REDIS_PASSWORD}.
     *  Vacío por defecto, igual que el resto de secretos opcionales
     *  de esta clase. */
    private String redisPassword = "";

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
    public String getOtlpEndpoint() { return otlpEndpoint; }
    public void setOtlpEndpoint(String otlpEndpoint) { this.otlpEndpoint = otlpEndpoint; }
    public String getCatalogInternalToken() { return catalogInternalToken; }
    public void setCatalogInternalToken(String catalogInternalToken) { this.catalogInternalToken = catalogInternalToken; }
    public String getCatalogBaseUrl() { return catalogBaseUrl; }
    public void setCatalogBaseUrl(String catalogBaseUrl) { this.catalogBaseUrl = catalogBaseUrl; }
    public int getReadyTimeoutSeconds() { return readyTimeoutSeconds; }
    public void setReadyTimeoutSeconds(int readyTimeoutSeconds) {
        this.readyTimeoutSeconds = readyTimeoutSeconds;
    }
    public String getRedisHost() { return redisHost; }
    public void setRedisHost(String redisHost) { this.redisHost = redisHost; }
    public String getRedisPort() { return redisPort; }
    public void setRedisPort(String redisPort) { this.redisPort = redisPort; }
    public String getRedisPassword() { return redisPassword; }
    public void setRedisPassword(String redisPassword) { this.redisPassword = redisPassword; }
}