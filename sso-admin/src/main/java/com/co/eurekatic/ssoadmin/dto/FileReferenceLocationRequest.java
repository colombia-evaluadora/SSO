package com.co.eurekatic.ssoadmin.dto;

import jakarta.validation.constraints.NotBlank;

/**
 * V-file-reference-admin — el admin elige {@code schemaName}/{@code
 * tableName} desde los selects poblados con el catálogo real de un
 * query-service (ver {@code GET /query-service-<instance>/tables},
 * el mismo endpoint que ya usa el picker de Writes), en vez de
 * escribirlos a mano. {@code urls3} no viaja aquí: {@link
 * com.co.eurekatic.ssoadmin.service.FileReferenceLocationAdminService#upsert}
 * lo relee directamente de la fila destino para que el registro
 * nunca quede desincronizado del dato real.
 */
public record FileReferenceLocationRequest(
        @NotBlank String schemaName,
        @NotBlank String tableName
) {}
