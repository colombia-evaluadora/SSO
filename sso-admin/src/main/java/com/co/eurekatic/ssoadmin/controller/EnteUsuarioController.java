package com.co.eurekatic.ssoadmin.controller;

import com.co.eurekatic.common.security.AuthPrincipal;
import com.co.eurekatic.ssoadmin.dto.EnteUsuarioRequest;
import com.co.eurekatic.ssoadmin.dto.EnteUsuarioResponse;
import com.co.eurekatic.ssoadmin.dto.TenteResponse;
import com.co.eurekatic.ssoadmin.dto.TrolResponse;
import com.co.eurekatic.ssoadmin.service.EnteUsuarioAdminService;
import jakarta.validation.Valid;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

/**
 * V-ente-admin — nivel-admin-sso para dar de alta/baja usuarios de
 * Ente Territorial (academico_test.TENTE_USUARIO, V150). Cae bajo la
 * regla catch-all de {@code SecurityConfig} ({@code ssoAdminAccessManager})
 * igual que el resto de endpoints de este módulo: necesita una fila
 * {@code endpoint} y un {@code role_endpoint} bindeado a quien deba
 * poder usarlo -- ver {@code postgres/migrations/V153__seed_ente_usuario_endpoints.sql}
 * (gateado a ADMIN, "nivel admin sso" pedido explícitamente, no
 * restringido a CEVAL-SUPER_ADMINISTRADOR como el audit-revert).
 */
@RestController
@RequestMapping("/ente")
public class EnteUsuarioController {

    private final EnteUsuarioAdminService service;

    public EnteUsuarioController(EnteUsuarioAdminService service) {
        this.service = service;
    }

    @GetMapping("/listar")
    public List<TenteResponse> listar() {
        return service.listarEntes();
    }

    @GetMapping("/roles")
    public List<TrolResponse> roles() {
        return service.listarRoles();
    }

    @PostMapping("/usuario/bind")
    public EnteUsuarioResponse bind(@Valid @RequestBody EnteUsuarioRequest req) {
        return service.bind(req, currentUserId());
    }

    @DeleteMapping("/usuario/unbind")
    public EnteUsuarioResponse unbind(@RequestParam Long fkTente, @RequestParam Long fkRol,
                                      @RequestParam Long fkUsuario) {
        return service.unbind(fkTente, fkRol, fkUsuario, currentUserId());
    }

    /** Null para tokens legado sin claim {@code uid} -- el servicio lo tolera (queda NULL en app.user_id). */
    private Long currentUserId() {
        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        if (auth != null && auth.getPrincipal() instanceof AuthPrincipal p) {
            return p.userId();
        }
        return null;
    }
}
