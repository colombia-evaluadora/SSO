package com.co.eurekatic.auth.client;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientResponseException;

import com.co.eurekatic.auth.web.dto.EstadoCuentaFuncionarioResponse;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Cliente servicio a servicio hacia la superficie {@code /internal/**} de
 * sso-admin, protegida por {@code X-Internal-Token} ({@code SSO_INTERNAL_TOKEN},
 * el mismo secreto que ya usan api-gateway y query-service). Es el sentido
 * inverso de {@code SessionInvalidationClient} (sso-admin -> auth-center).
 *
 * <p>Hoy solo lo usa el cambio de correo de un funcionario: la emision del
 * token de activacion y el correo {@code account-activation} viven en
 * sso-admin ({@code UserAdminService#reactivateAfterEmailChange}) y no se
 * duplican aca.
 */
@Component
public class SsoAdminInternalClient {

    private static final Logger log = LoggerFactory.getLogger(SsoAdminInternalClient.class);

    /** Contrato de cable con {@code InternalTokenFilter} de sso-admin. */
    static final String HEADER = "X-Internal-Token";

    private final RestClient http;
    private final String token;

    @Autowired
    public SsoAdminInternalClient(
            @Value("${sso.admin.base-url:http://sso-admin:8083}") String baseUrl,
            @Value("${sso.internal.token:}") String token) {
        this(RestClient.builder().baseUrl(baseUrl).build(), token);
    }

    SsoAdminInternalClient(RestClient http, String token) {
        this.http = http;
        this.token = token;
    }

    /**
     * Pide a sso-admin dejar la cuenta en PENDING_ACTIVATION y mandar la
     * activacion al correo nuevo. Un 4xx de sso-admin (cambio no ocurrido,
     * cuenta inexistente o inactiva) se devuelve como
     * {@link IllegalArgumentException} con el mensaje original (-> 400); un
     * fallo de infraestructura, como {@link IllegalStateException} (-> 500).
     */
    public void reactivateAfterEmailChange(String correoAnterior, String correoNuevo, String app) {
        if (token == null || token.isBlank()) {
            throw new IllegalStateException("sso.internal.token no configurado en auth-center");
        }
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("correoAnterior", correoAnterior);
        body.put("correoNuevo", correoNuevo);
        try {
            http.post()
                    .uri(b -> b.path("/internal/funcionario/reactivar-por-cambio-de-correo")
                            .queryParam("app", app).build())
                    .header(HEADER, token)
                    .contentType(MediaType.APPLICATION_JSON)
                    .body(body)
                    .retrieve()
                    .toBodilessEntity();
        } catch (RestClientResponseException e) {
            int status = e.getStatusCode().value();
            // Cualquier 4xx es un rechazo de negocio (incluye 422 de correo
            // invalido, que antes caia como 500 generico y ocultaba el motivo).
            if (status >= 400 && status < 500 && status != 401 && status != 403) {
                String msg = messageOf(e);
                log.warn("sso-admin rechazo la reactivacion por cambio de correo ({}): {}", status, msg);
                throw new IllegalArgumentException(msg);
            }
            log.error("sso-admin respondio {} al reactivar por cambio de correo", status, e);
            throw new IllegalStateException("No se pudo enviar el correo de activación", e);
        }
    }

    /**
     * Estado de cuenta por correo (tabla de funcionarios). Un 400 de
     * sso-admin (p. ej. mas de 200 correos) -> {@link IllegalArgumentException}
     * (400); otro fallo -> {@link IllegalStateException} (500).
     */
    public List<EstadoCuentaFuncionarioResponse> accountStatus(List<String> correos) {
        requireToken();
        try {
            EstadoCuentaFuncionarioResponse[] out = http.post()
                    .uri("/internal/funcionario/estado-cuenta")
                    .header(HEADER, token)
                    .contentType(MediaType.APPLICATION_JSON)
                    .body(Map.of("correos", correos))
                    .retrieve()
                    .body(EstadoCuentaFuncionarioResponse[].class);
            return out == null ? List.of() : List.of(out);
        } catch (RestClientResponseException e) {
            int status = e.getStatusCode().value();
            if (status == 400) {
                throw new IllegalArgumentException(messageOf(e, "No se pudo consultar el estado de las cuentas"));
            }
            log.error("sso-admin respondio {} al consultar estado de cuentas", status, e);
            throw new IllegalStateException("No se pudo consultar el estado de las cuentas", e);
        }
    }

    /**
     * Reenvia la activacion de un funcionario pendiente. A diferencia de
     * {@link #reactivateAfterEmailChange}, el front necesita distinguir
     * 404 (sin cuenta) y 409 (cuenta activa/inactiva): se propagan con su
     * status y mensaje via {@link SsoAdminStatusException}; un 400 sigue
     * siendo {@link IllegalArgumentException}.
     */
    public void resendActivation(String correo, String app) {
        requireToken();
        try {
            http.post()
                    .uri(b -> b.path("/internal/funcionario/reenviar-activacion")
                            .queryParam("app", app).build())
                    .header(HEADER, token)
                    .contentType(MediaType.APPLICATION_JSON)
                    .body(Map.of("correo", correo))
                    .retrieve()
                    .toBodilessEntity();
        } catch (RestClientResponseException e) {
            int status = e.getStatusCode().value();
            if (status == 404 || status == 409) {
                throw new SsoAdminStatusException(status, messageOf(e));
            }
            if (status == 400) {
                throw new IllegalArgumentException(messageOf(e));
            }
            log.error("sso-admin respondio {} al reenviar la activacion", status, e);
            throw new IllegalStateException("No se pudo enviar el correo de activación", e);
        }
    }

    private void requireToken() {
        if (token == null || token.isBlank()) {
            throw new IllegalStateException("sso.internal.token no configurado en auth-center");
        }
    }

    private static String messageOf(RestClientResponseException e) {
        return messageOf(e, "No se pudo enviar el correo de activación");
    }

    private static String messageOf(RestClientResponseException e, String fallback) {
        try {
            Map<?, ?> m = e.getResponseBodyAs(Map.class);
            Object msg = m == null ? null : m.get("message");
            if (msg != null && !msg.toString().isBlank()) return msg.toString();
        } catch (RuntimeException ignored) {
            // cuerpo no JSON: mensaje generico abajo
        }
        return fallback;
    }
}
