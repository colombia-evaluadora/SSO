package com.co.eurekatic.ssoadmin.dto;

import com.co.eurekatic.common.entity.WriteType;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

/**
 * Request body for {@code POST /write/save} and
 * {@code PUT /write/update}. The {@code uuid} is the public
 * handle clients send to {@code query-service}; uniqueness on
 * it is enforced at the DB level.
 *
 * <p>{@code columns} and {@code keyColumns} are JSON arrays of
 * column names (e.g. {@code "[\"ID\",\"NAME\"]"}). Stored as
 * strings — the consumer ({@code query-service}) parses them
 * once on read. We deliberately do NOT deserialize into
 * {@code List<String>} here so the admin UI can store the
 * array in the exact shape the low-code renderer expects.
 *
 * <p>{@code tableName} must be qualified ({@code schema.table}).
 * The catalog endpoint returns it verbatim; {@code query-service}
 * re-validates it against an identifier regex before
 * interpolating — defense in depth.
 *
 * <p>{@code microserviceId} binds the write to a backing
 * {@code query-service-<instance>} container. Nullable: a
 * {@code null} value keeps the write "global" so any instance
 * with the right datasource may serve it (legacy behavior,
 * still useful for the canonical single-instance deployment).
 * When non-null the service layer enforces that the referenced
 * row is {@code kind=QUERY} — binding a {@code REST} row is
 * rejected with 400 INVALID_REQUEST because no container runs
 * there to accept the write.
 */
public record WriteDefinitionRequest(
        Long id,
        @NotBlank @Size(max = 64)   String uuid,
        @NotNull                    WriteType writeType,
        @NotBlank @Size(max = 200)  String tableName,
        @NotBlank                   String columns,
        String                      keyColumns,
        Long                        microserviceId
) {}
