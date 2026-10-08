package com.co.eurekatic.auth.web;

import com.co.eurekatic.auth.client.SsoAdminInternalClient;
import com.co.eurekatic.auth.web.dto.CambioCorreoFuncionarioRequest;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

/**
 * Cambio de correo de un funcionario: los fronts lo llaman DESPUES de guardar
 * la edicion (que corre por query-service y sincroniza public.users en V215,
 * sin poder mandar correos). La cuenta vuelve a PENDING_ACTIVATION y se envia
 * la activacion al correo nuevo con el enlace de la app.
 *
 * <p>Va junto a {@code /register/{cval,pigse}/funcionario} y con su mismo
 * gate (role_endpoint via AuthCenterAccessManager, sembrado en V550 para los
 * mismos roles que registran funcionarios). La app sale de la RUTA, igual que
 * en el alta, no de un parametro del caller. El trabajo real lo hace
 * sso-admin por {@code /internal/**} (ver {@link SsoAdminInternalClient}).
 */
@RestController
public class FuncionarioCorreoController {

    static final String APP_CVAL = "COLOMBIA-EVALUADORA";
    static final String APP_PIGSE = "PIGSE";

    private final SsoAdminInternalClient ssoAdmin;

    public FuncionarioCorreoController(SsoAdminInternalClient ssoAdmin) {
        this.ssoAdmin = ssoAdmin;
    }

    @PostMapping("/register/cval/funcionario/reactivar-por-cambio-de-correo")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void reactivarCval(@Valid @RequestBody CambioCorreoFuncionarioRequest req) {
        ssoAdmin.reactivateAfterEmailChange(req.correoAnterior(), req.correoNuevo(), APP_CVAL);
    }

    @PostMapping("/register/pigse/funcionario/reactivar-por-cambio-de-correo")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void reactivarPigse(@Valid @RequestBody CambioCorreoFuncionarioRequest req) {
        ssoAdmin.reactivateAfterEmailChange(req.correoAnterior(), req.correoNuevo(), APP_PIGSE);
    }
}
