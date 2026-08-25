package com.co.eurekatic.ssoadmin.dto;

import jakarta.validation.constraints.NotNull;

/**
 * V-audit-revert — identifica el cambio a revertir por su clave natural
 * en {@code auditoria.audit_log}: {@code (lsn, seq)} apunta a UN evento
 * de cambio de fila puntual, no a la transacción completa (revertir
 * varias filas de una misma transacción sigue fuera de alcance).
 *
 * <p>{@code dryRun} por defecto {@code true} — deliberado: este
 * endpoint muta datos de producción, nunca debe ejecutar por accidente
 * porque el caller olvidó el flag.
 */
public record AuditRevertRequest(
        @NotNull Long lsn,
        @NotNull Long seq,
        Boolean dryRun
) {
    public boolean isDryRun() {
        return dryRun == null || dryRun;
    }
}
