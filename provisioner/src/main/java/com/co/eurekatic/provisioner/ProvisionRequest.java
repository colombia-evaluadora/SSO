package com.co.eurekatic.provisioner;

import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;

/**
 * Request body for {@code POST /provision}. Matches the
 * shape sso-admin's {@code HttpContainerProvisioner} sends —
 * field names are camelCase to match the
 * {@link com.co.eurekatic.ssoadmin.provisioner.ProvisionSpec}
 * record on the sso-admin side.
 */
public record ProvisionRequest(
        /** Container name suffix. The provisioner prepends
         *  {@code query-service-} (matches the convention
         *  query-service's InstanceNameResolver applies). */
        @NotBlank String instanceName,

        /** {@code postgres | oracle | sqlserver}. */
        @NotBlank String dialect,

        /** JDBC URL handed to the container as QUERY_DS_URL. */
        @NotBlank String jdbcUrl,

        @NotBlank String dbUsername,
        String dbPassword,

        @Min(1) int poolSize
) {}