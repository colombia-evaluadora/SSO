package com.co.eurekatic.common.audit;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import java.util.regex.Pattern;

/**
 * Extrae el mismo contexto HTTP que query-service ya captura en
 * {@code QueryService.injectRequestParams} — IP del cliente, headers en
 * whitelist, request-id, método HTTP y un snapshot del body con claves
 * sensibles redactadas — pero como un objeto de valor reusable en vez de
 * un mapa de placeholders {@code :CONTEXT.*}.
 *
 * <p>Extraído en V-audit-ctx-3 para que auth-center/file-service/sso-admin
 * puedan fijar las mismas GUCs de sesión que query-service sin duplicar
 * ~100 líneas de lógica de IP/headers/redacción. query-service SIGUE
 * teniendo su propia copia de esta lógica (no depende de {@code common}
 * para esto) porque necesita el resultado como placeholders de texto para
 * su CTE {@code WITH _ctx AS MATERIALIZED (...)}, no como un objeto Java —
 * mantener las dos copias en sync es un costo aceptado, ver
 * {@code docs/etiqueta-auditoria-cdc-analisis.md}.
 *
 * <p>Silenciosamente no-op ({@link Optional#empty()}) cuando no hay un
 * {@link jakarta.servlet.http.HttpServletRequest} ligado al hilo actual —
 * mismo guard que {@code injectRequestParams} — así que es seguro llamarla
 * desde código que a veces corre fuera de un request HTTP (p.ej. un
 * listener de RabbitMQ) sin necesidad de un chequeo aparte en cada caller.
 */
public final class AuditContextExtractor {

    private AuditContextExtractor() {}

    /**
     * Headers permitidos en {@code app.headers}. Deliberadamente NO incluye
     * {@code Authorization}/{@code Cookie} — nunca deben llegar a
     * ClickHouse. {@code X-Forwarded-For} tampoco está acá porque ya se
     * captura aparte como {@code app.client_ip}.
     */
    private static final List<String> HEADER_WHITELIST =
            List.of("User-Agent", "Accept-Language", "Referer");

    /**
     * Nombres de placeholder que nunca deben llegar a ClickHouse en texto
     * plano dentro de {@code app.request_body}. Se compara contra el nombre
     * "local" (después del namespace — {@code BODY.PASSWORD} → {@code
     * PASSWORD}), case-insensitive.
     */
    private static final Pattern SENSITIVE_KEY_PATTERN =
            Pattern.compile("(?i).*(TOKEN|SECRET|PASSWORD|CONTRASENA|CONTRASEÑA).*");

    private static final ObjectMapper MAPPER = new ObjectMapper();

    /**
     * Construye el {@link AuditContext} de la petición HTTP actual, o
     * {@link Optional#empty()} si no hay ninguna ligada a este hilo (llamada
     * no-HTTP, test sin {@code MockHttpServletRequest}, etc).
     *
     * @param requestBody snapshot del body/params que el caller ya armó
     *                     (namespaced o no, da igual — solo se usa para
     *                     redactar y serializar), o {@code null}/vacío si
     *                     no aplica para este write (p.ej. file-service no
     *                     tiene un "body de negocio" para un upload).
     */
    public static Optional<AuditContext> fromCurrentRequest(Map<String, Object> requestBody) {
        if (!(RequestContextHolder.getRequestAttributes() instanceof ServletRequestAttributes sra)) {
            return Optional.empty();
        }
        var req = sra.getRequest();

        Map<String, Object> redactedBody = requestBody == null ? Map.of() : redact(requestBody);

        String requestId = req.getHeader("X-Request-Id");
        if (requestId == null || requestId.isBlank()) {
            requestId = UUID.randomUUID().toString();
        } else if (requestId.length() > 100) {
            // El trigger trunca a 100 (ver fn_audit_ctx / LowCardinality en
            // ClickHouse) — cortamos aquí para no mandar ruido de más.
            requestId = requestId.substring(0, 100);
        }

        // client_ip: X-Client-Ip (api-gateway's ClientIpGlobalFilter,
        // autoritativo) → X-Forwarded-For (sin verificar, solo relevante
        // cuando NO se está detrás de ese gateway) → conexión TCP directa.
        String clientIp = req.getHeader("X-Client-Ip");
        if (clientIp == null || clientIp.isBlank()) {
            clientIp = req.getHeader("X-Forwarded-For");
            if (clientIp != null && !clientIp.isBlank()) {
                clientIp = clientIp.split(",")[0].trim();
            }
        }
        if (clientIp == null || clientIp.isBlank()) {
            clientIp = req.getRemoteAddr();
        }
        if (clientIp != null && clientIp.isBlank()) {
            clientIp = null;
        }

        String userAgent = req.getHeader("User-Agent");
        if (userAgent != null && userAgent.isBlank()) {
            userAgent = null;
        }

        Map<String, String> headers = new LinkedHashMap<>();
        for (String name : HEADER_WHITELIST) {
            String value = req.getHeader(name);
            if (value != null && !value.isBlank()) {
                headers.put(name.toLowerCase(Locale.ROOT), value);
            }
        }

        String requestBodyJson = redactedBody.isEmpty() ? null : toJson(redactedBody);

        return Optional.of(new AuditContext(
                requestId,
                req.getMethod(),
                clientIp,
                userAgent,
                headers,
                requestBodyJson));
    }

    /**
     * Profundidad máxima al bajar por el body. Un DTO de negocio no
     * llega ni de lejos; el tope está para que un mapa con un ciclo
     * (o un JSON absurdamente anidado) no se lleve el hilo por
     * delante. Al tocar el fondo se redacta la rama entera: preferimos
     * perder una rama de la auditoría antes que arriesgarnos a
     * escribir en claro algo que no hemos podido inspeccionar.
     */
    private static final int MAX_PROFUNDIDAD = 12;

    private static final String REDACTADO = "[REDACTED]";

    /**
     * Copia {@code source} redactando los valores cuyas keys matchean
     * {@link #SENSITIVE_KEY_PATTERN}.
     *
     * <p><b>Baja por los valores anidados.</b> Antes sólo miraba el
     * primer nivel, lo que bastaba para los bodies ya aplanados del
     * catálogo ({@code BODY.USUARIO.PASSWORD} → se corta en el primer
     * punto → {@code USUARIO.PASSWORD} → matchea). Pero
     * {@code FuncionarioRegistrationService} construye su snapshot con
     * {@code objectMapper.convertValue(dto, Map.class)}, y ahí un
     * objeto anidado llega como un {@code Map} dentro del valor: la
     * key del primer nivel es {@code credenciales}, que no matchea, y
     * el {@code password} de dentro se serializaba tal cual a
     * {@code app.request_body} — es decir, a ClickHouse.
     *
     * <p>También recorre listas, porque una colección de objetos
     * (varios contactos, varios usuarios en un alta masiva) esconde el
     * mismo problema un nivel más abajo.
     */
    public static Map<String, Object> redact(Map<String, Object> source) {
        return redactMapa(source, 0);
    }

    private static Map<String, Object> redactMapa(Map<String, Object> source, int profundidad) {
        Map<String, Object> copy = new LinkedHashMap<>();
        for (Map.Entry<String, Object> e : source.entrySet()) {
            String key = e.getKey();
            int dot = key.indexOf('.');
            String localName = dot >= 0 ? key.substring(dot + 1) : key;
            copy.put(key, SENSITIVE_KEY_PATTERN.matcher(localName).matches()
                    ? REDACTADO
                    : redactValor(e.getValue(), profundidad + 1));
        }
        return copy;
    }

    /** Redacta recursivamente mapas y listas; cualquier otro valor pasa tal cual. */
    private static Object redactValor(Object valor, int profundidad) {
        if (valor == null) {
            return null;
        }
        if (profundidad >= MAX_PROFUNDIDAD) {
            return REDACTADO;
        }
        if (valor instanceof Map<?, ?> mapa) {
            Map<String, Object> comoStrings = new LinkedHashMap<>();
            for (Map.Entry<?, ?> e : mapa.entrySet()) {
                comoStrings.put(String.valueOf(e.getKey()), e.getValue());
            }
            return redactMapa(comoStrings, profundidad);
        }
        if (valor instanceof Iterable<?> iterable) {
            List<Object> lista = new ArrayList<>();
            for (Object item : iterable) {
                lista.add(redactValor(item, profundidad + 1));
            }
            return lista;
        }
        return valor;
    }

    private static String toJson(Object value) {
        try {
            return MAPPER.writeValueAsString(value);
        } catch (JsonProcessingException e) {
            return null;
        }
    }
}
