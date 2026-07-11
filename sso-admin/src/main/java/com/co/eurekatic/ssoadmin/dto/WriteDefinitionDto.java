package com.co.eurekatic.ssoadmin.dto;

import com.co.eurekatic.common.entity.WriteDefinition;
import com.co.eurekatic.common.entity.WriteType;

import java.util.List;

/**
 * Read-side response shape for {@code GET /getWrite?uuid=...}.
 * Consumed by {@code query-service}'s
 * {@code CatalogClient.resolveWrite} call.
 *
 * <p>This is the contract of the new write-catalog endpoint —
 * not in the legacy. The fields map one-to-one to the spec
 * (§6.1): uuid, type, table, columns, keyColumns. We DO NOT
 * serialize the bound roles; authorization is enforced inside
 * the catalog endpoint (a 403 response), the consumer never
 * sees the role list.
 *
 * <p>The {@code columns} and {@code keyColumns} lists are
 * deserialized once here so {@code query-service} doesn't have
 * to JSON-parse the strings the admin UI stored. We use
 * Jackson's record-component auto-discovery; the
 * {@code columns} field on the entity stays a String for
 * forward-compatibility with future schema-only changes.
 */
public record WriteDefinitionDto(
        Long idWriteDefinition,
        String uuid,
        WriteType writeType,
        String tableName,
        List<String> columns,
        List<String> keyColumns
) {
    public static WriteDefinitionDto fromEntity(WriteDefinition w) {
        return new WriteDefinitionDto(
                w.getId(),
                w.getUuid(),
                w.getWriteType(),
                w.getTableName(),
                parseArray(w.getColumns()),
                parseArray(w.getKeyColumns()));
    }

    /**
     * Parses a JSON array literal (e.g. {@code ["A","B"]}) into
     * a {@code List<String>}. Returns an empty list for null or
     * blank input (the {@code keyColumns} column is nullable on
     * INSERT definitions). Throws {@link IllegalStateException}
     * if the stored value is malformed — that signals a
     * corrupted admin row and should fail loud, not silently
     * degrade.
     */
    private static List<String> parseArray(String json) {
        if (json == null || json.isBlank()) {
            return List.of();
        }
        try {
            com.fasterxml.jackson.databind.JavaType listOfString =
                    com.fasterxml.jackson.databind.type.TypeFactory.defaultInstance()
                            .constructCollectionType(List.class, String.class);
            return com.fasterxml.jackson.databind.json.JsonMapper.builder().build()
                    .readValue(json, listOfString);
        } catch (com.fasterxml.jackson.core.JsonProcessingException e) {
            throw new IllegalStateException(
                    "WriteDefinition " + json + " is not a valid JSON string array", e);
        }
    }
}
