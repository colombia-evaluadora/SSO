package com.co.eurekatic.ssoadmin.controller.internal;

import com.co.eurekatic.ssoadmin.dto.AccountStatusRequest;
import com.co.eurekatic.ssoadmin.dto.AccountStatusResponse;
import com.co.eurekatic.ssoadmin.dto.EmailChangeReactivationRequest;
import com.co.eurekatic.ssoadmin.dto.ResendActivationByEmailRequest;
import com.co.eurekatic.ssoadmin.service.UserAdminService;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

/**
 * Superficie interna (servicio a servicio) para el cambio de correo de un
 * funcionario. La consume SOLO auth-center, desde
 * {@code POST /register/{cval,pigse}/funcionario/reactivar-por-cambio-de-correo}
 * (gate role_endpoint de auth-center, los mismos roles que registran
 * funcionarios). Aca no hay JWT de usuario: la protege
 * {@code InternalTokenFilter} con {@code X-Internal-Token}
 * ({@code SSO_INTERNAL_TOKEN}), como el resto de {@code /internal/**}.
 *
 * <p>Por que aca y no duplicado en auth-center: el token de activacion, la
 * resolucion del enlace por app y la publicacion de {@code account-activation}
 * ya viven en {@link UserAdminService}; asi no hay dos implementaciones.
 * Tampoco se abre SSO-ADMIN (role_app) a roles de rector/funcionario.
 */
@RestController
@RequestMapping("/internal")
public class InternalFuncionarioController {

    private final UserAdminService service;

    public InternalFuncionarioController(UserAdminService service) {
        this.service = service;
    }

    @PostMapping("/funcionario/reactivar-por-cambio-de-correo")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void reactivateAfterEmailChange(@Valid @RequestBody EmailChangeReactivationRequest req,
                                           @RequestParam("app") String app) {
        service.reactivateAfterEmailChange(req, app);
    }

    /** Estado de cuenta por correo para la tabla de funcionarios (CE / PIGSE). */
    @PostMapping("/funcionario/estado-cuenta")
    public List<AccountStatusResponse> accountStatus(@Valid @RequestBody AccountStatusRequest req) {
        return service.accountStatusByEmails(req.correos());
    }

    /** Reenvia la activacion SOLO si la cuenta sigue en PENDING_ACTIVATION (404 / 409 si no). */
    @PostMapping("/funcionario/reenviar-activacion")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void resendActivation(@Valid @RequestBody ResendActivationByEmailRequest req,
                                 @RequestParam("app") String app) {
        service.resendActivationByEmail(req.correo(), app);
    }
}
