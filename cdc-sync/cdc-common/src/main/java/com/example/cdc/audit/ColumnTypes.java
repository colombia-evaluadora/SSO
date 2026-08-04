package com.example.cdc.audit;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;

import java.util.List;
import java.util.Map;

@JsonIgnoreProperties(ignoreUnknown = true)
public record ColumnTypes(
        String version,
        Map<String, Table> tables
) {
    @JsonIgnoreProperties(ignoreUnknown = true)
    public record Table(
            String schema,
            Map<String, Column> columns
    ) {}

    @JsonIgnoreProperties(ignoreUnknown = true)
    public record Column(
            String pgType,
            String slot
    ) {
    }
}
