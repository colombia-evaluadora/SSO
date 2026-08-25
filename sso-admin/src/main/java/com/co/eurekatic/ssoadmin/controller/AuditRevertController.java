package com.co.eurekatic.ssoadmin.controller;

import com.co.eurekatic.common.security.AuthPrincipal;
import com.co.eurekatic.ssoadmin.dto.AuditRevertRequest;
import com.co.eurekatic.ssoadmin.dto.AuditRevertResponse;
import com.co.eurekatic.ssoadmin.service.AuditRevertService;
import jakarta.validation.Valid;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * V-audit-revert — fase 2: INSERT (revertido como soft-delete), UPDATE
 * genérico (cualquier columna) y DELETE físico (rechazado — ver
 * {@link AuditRevertService}). Cae bajo la regla catch-all de {@code
 * SecurityConfig} ({@code ssoAdminAccessManager}) igual que el resto de
 * endpoints de este módulo: necesita una fila {@code endpoint} y un
 * {@code role_endpoint} bindeado a quien deba poder usarlo — dado lo
 * destructivo de la operación, esa asignación de rol debería quedar
 * MUY restringida (no ADMIN genérico) cuando se configure.
 *
 * <p>{@code dryRun=true} (el default del DTO) nunca escribe — solo
 * valida y muestra qué pasaría. Es la forma recomendada de usar este
 * endpoint antes de confirmar con {@code dryRun=false}.
 */
@RestController
@RequestMapping("/audit")
public class AuditRevertController {

    private final AuditRevertService service;

    public AuditRevertController(AuditRevertService service) {
        this.service = service;
    }

    @PostMapping("/revert")
    public AuditRevertResponse revert(@Valid @RequestBody AuditRevertRequest req) {
        if (req.isDryRun()) {
            return service.preview(req.lsn(), req.seq());
        }
        return service.revert(req.lsn(), req.seq(), currentUserId());
    }

    /** Null para tokens legado sin claim {@code uid} — el servicio lo tolera (queda NULL en app.user_id). */
    private Long currentUserId() {
        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        if (auth != null && auth.getPrincipal() instanceof AuthPrincipal p) {
            return p.userId();
        }
        return null;
    }
}
