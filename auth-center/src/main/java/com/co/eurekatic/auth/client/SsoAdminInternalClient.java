package com.co.eurekatic.auth.client;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientResponseException;

import java.util.LinkedHashMap;
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

    private static String messageOf(RestClientResponseException e) {
        try {
            Map<?, ?> m = e.getResponseBodyAs(Map.class);
            Object msg = m == null ? null : m.get("message");
            if (msg != null && !msg.toString().isBlank()) return msg.toString();
        } catch (RuntimeException ignored) {
            // cuerpo no JSON: mensaje generico abajo
        }
        return "No se pudo enviar el correo de activación";
    }
}
