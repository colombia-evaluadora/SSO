package com.co.eurekatic.ssoadmin.dto;

import java.time.Instant;

/**
 * V-file-reference-admin — proyección de una fila de {@code
 * public.file_reference_location} (V143/V147): dónde vive
 * realmente el {@code pk_tarchivo} que file-service resuelve en
 * cada descarga/visor. Ver {@code FileReferenceLocationAdminService}.
 */
public record FileReferenceLocationResponse(
        long pkTarchivo,
        String schemaName,
        String tableName,
        String urls3,
        Instant createdAt) {
}
