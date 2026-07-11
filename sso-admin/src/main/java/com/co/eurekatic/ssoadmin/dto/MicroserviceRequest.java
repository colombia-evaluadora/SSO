package com.co.eurekatic.ssoadmin.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

/**
 * Request body for {@code POST /microservice/save} and
 * {@code PUT /microservice/update} (legacy used the same DTO
 * with an optional {@code id} for the update variant). The
 * create variant leaves {@code id} null and the server assigns
 * it.
 *
 * <p>The seven trailing fields ({@code kind} … {@code
 * instanceName}) drive the dynamic query-service provisioner
 * when {@link #kind} is {@code "QUERY"}. They are nullable for
 * the legacy {@code "REST"} flow; cross-field validation
 * ("if kind=QUERY then dialect/jdbcUrl/dbUsername are
 * required") lives in
 * {@code MicroserviceService.create} — Bean Validation's
 * {@code @NotBlank} annotations don't compose well across
 * fields, so a manual check there is cleaner than a
 * class-level constraint.
 */
public record MicroserviceRequest(
        Long id,
        @NotBlank @Size(max = 200) String serviceId,
        @Size(max = 500) String description,
        @Size(max = 500) String requestUri,
        @Size(max = 500) String targetUriPath,
        @Size(max = 500) String targetUrlHost,
        @Size(max = 10)  String targetUrlPort,

        /* ====================== provisioning (QUERY kind) ====================== */

        /**
         * Defaults to {@code "REST"} at the service layer
         * when the client omits it. Accepts only the two
         * known discriminators; anything else is rejected by
         * {@code MicroserviceService} with a 400.
         */
        @Pattern(regexp = "REST|QUERY",
                 message = "kind must be REST or QUERY")
        String kind,

        @Size(max = 40) String dialect,
        @Size(max = 1000) String jdbcUrl,
        @Size(max = 120) String dbUsername,
        @Size(max = 500) String dbPassword,
        Integer poolSize,
        @Size(max = 120) String instanceName,
        /**
         * Optional "primary" {@code id_app} for this
         * microservice. Nullable — same rationale as
         * {@link RouteRequest#appId()}: rows created before
         * the {@code 06-create-app-tables} migration land
         * with {@code app_id=null}.
         */
        Long appId
) {}