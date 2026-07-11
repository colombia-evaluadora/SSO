package com.co.eurekatic.ssoadmin.provisioner;

/**
 * Spec passed to {@link ContainerProvisioner#provision(ProvisionSpec)}
 * — the projection of a {@code kind=QUERY} {@code microservice}
 * row into the bits the provisioner sidecar needs to spin up a
 * fresh {@code query-service} container.
 *
 * <p>The {@code instanceName} is the suffix only; the
 * provisioner pre-pends {@code query-service-} (matching the
 * convention query-service's {@code InstanceNameResolver}
 * applies).
 *
 * @param instanceName  The user-chosen suffix, e.g. {@code "oracle-dev"}.
 *                      Becomes the container name
 *                      {@code query-service-<instanceName>} and the
 *                      Eureka service-id of the same shape.
 * @param dialect       {@code postgres | oracle | sqlserver}.
 * @param jdbcUrl       Full JDBC URL handed to the container as
 *                      {@code QUERY_DS_URL}.
 * @param dbUsername    DB user.
 * @param dbPassword    DB password (sensitive).
 * @param poolSize      HikariCP {@code maximum-pool-size}; pass
 *                      {@code 10} as the query-service default
 *                      when the row doesn't override it.
 */
public record ProvisionSpec(
        String instanceName,
        String dialect,
        String jdbcUrl,
        String dbUsername,
        String dbPassword,
        int poolSize
) {}