package com.co.eurekatic.ssoadmin.dto;

import java.util.List;

/**
 * V-audit-revert — respuesta tanto de un preview ({@code dryRun=true})
 * como de una ejecución real. {@code applied=false} en un dry-run deja
 * claro que nada se escribió todavía.
 *
 * <p>Fase 2: {@code cambios} generaliza el {@code activeBefore}/
 * {@code activeAfter} de fase 1 — una entrada por cada columna que se
 * revierte, sea el toggle de {@code active} de un soft-delete/restore,
 * el {@code active=true→false} de deshacer un INSERT, o cualquier
 * columna que cambió en un UPDATE. Ver {@code AuditRevertService}.
 */
public record AuditRevertResponse(
        boolean applied,
        String tabla,
        String operacionOriginal,   // 'c' | 'u' — la operación original en ClickHouse
        String pkColumn,
        String pkValue,
        List<ColumnRevert> cambios,
        String originalRequestId,
        String originalEtiqueta,
        String originalAppUser,
        String message
) {
    /**
     * Un cambio de columna a revertir. {@code antes} es el valor que dejó
     * el cambio original (y el que Postgres debe tener todavía para que
     * el revert no pise algo posterior); {@code despues} es el valor al
     * que se revierte.
     */
    public record ColumnRevert(String columna, Object antes, Object despues) {}
}
