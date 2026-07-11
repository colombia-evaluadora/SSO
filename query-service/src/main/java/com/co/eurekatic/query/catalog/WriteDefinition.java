package com.co.eurekatic.query.catalog;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;

import java.util.List;

/**
 * Wire format of the {@code /getWrite} response. The
 * {@code columns} and {@code keyColumns} lists are already
 * deserialized from the entity's JSON string by sso-admin.
 *
 * <p>{@code writeType} is the {@code INSERT} / {@code UPDATE}
 * enum. Anything else is a corrupted catalog row and we
 * treat it as a runtime error.
 */
@JsonIgnoreProperties(ignoreUnknown = true)
public record WriteDefinition(
        @JsonProperty("idWriteDefinition") Long idWriteDefinition,
        @JsonProperty("uuid") String uuid,
        @JsonProperty("writeType") String writeType,
        @JsonProperty("tableName") String tableName,
        @JsonProperty("columns") List<String> columns,
        @JsonProperty("keyColumns") List<String> keyColumns
) {
    public boolean isInsert() {
        return "INSERT".equalsIgnoreCase(writeType);
    }

    public boolean isUpdate() {
        return "UPDATE".equalsIgnoreCase(writeType);
    }
}