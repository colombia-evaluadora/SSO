package com.co.eurekatic.ssoadmin.dto;

/**
 * V-audit-revert — respuesta tanto de un preview ({@code dryRun=true})
 * como de una ejecución real. {@code applied=false} en un dry-run deja
 * claro que nada se escribió todavía.
 */
public record AuditRevertResponse(
        boolean applied,
        String tabla,
        String pkColumn,
        String pkValue,
        boolean activeBefore,   // valor actual en Postgres al momento del preview/ejecución
        boolean activeAfter,    // valor al que se revierte (fila_old_raw.active)
        String originalRequestId,
        String originalEtiqueta,
        String originalAppUser,
        String message
) {}
