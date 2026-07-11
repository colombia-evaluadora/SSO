package com.co.eurekatic.ssoadmin.dto;

import com.co.eurekatic.common.entity.Microservice;
import com.co.eurekatic.common.entity.WriteDefinition;
import com.co.eurekatic.common.entity.WriteType;

import java.time.LocalDateTime;
import java.util.LinkedHashSet;
import java.util.Set;
import java.util.stream.Collectors;

/**
 * Response shape for the write-definition CRUD endpoints.
 * Mirrors {@link QueryResponse}'s structure so the admin UI can
 * reuse the same table component.
 *
 * <p>{@code microserviceId} identifies the
 * {@code query-service-<instance>} that should serve this
 * write. Surfaced for the admin CRUD form so operators can
 * re-bind a write to a different instance (and so the table
 * picker can be wired per backing instance). A {@code null}
 * means "global" — any instance with the right datasource may
 * serve it.
 */
public record WriteDefinitionResponse(
        Long id,
        String uuid,
        WriteType writeType,
        String tableName,
        String columns,
        String keyColumns,
        LocalDateTime createdDate,
        Set<Long> roleIds,
        Long microserviceId
) {
    public static WriteDefinitionResponse fromEntity(WriteDefinition w) {
        Microservice m = w.getMicroservice();
        return new WriteDefinitionResponse(
                w.getId(),
                w.getUuid(),
                w.getWriteType(),
                w.getTableName(),
                w.getColumns(),
                w.getKeyColumns(),
                w.getCreatedDate(),
                w.getRoles().stream()
                        .map(com.co.eurekatic.common.entity.Role::getId)
                        .collect(Collectors.toCollection(LinkedHashSet::new)),
                m != null ? m.getId() : null);
    }
}
