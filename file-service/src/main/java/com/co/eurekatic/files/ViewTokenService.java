package com.co.eurekatic.files;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.security.InvalidKeyException;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Clock;
import java.time.Instant;
import java.util.Base64;

/**
 * Tokens firmados de un solo propósito: acceso de solo-lectura a UN
 * archivo concreto, por un tiempo corto, para un llamante que no
 * puede mandar cabeceras — un {@code <img src="...">} del navegador,
 * que no tiene forma de llevar {@code Authorization: Bearer}.
 *
 * <p>No son JWT. file-service sólo tiene la clave PÚBLICA del par
 * RS256 del SSO ({@code sso.jwt.public-key}) — puede verificar
 * tokens de sesión, pero no puede FIRMAR ninguno; emitir JWT nuevos
 * exigiría darle la clave privada, ensanchando quién puede acuñar
 * identidad en todo el sistema por una necesidad puramente local a
 * este servicio. En su lugar, HMAC-SHA256 con un secreto que
 * file-service genera y verifica él mismo — el mismo patrón que
 * {@code X-Internal-Token} (ver {@link DownloadController}), sólo
 * que acotado a un archivo concreto y con caducidad corta en vez de
 * ser un secreto de vida larga compartido con el catálogo.
 *
 * <p>Formato: {@code base64url(archivoId:expiryEpochSeconds).base64url(HMAC)}.
 * Auto-contenido — no hay estado del lado del servidor que consultar
 * para validar, así que no hay forma de revocar un token antes de
 * que expire. Aceptable para una vista de imagen de unos minutos; es
 * el mismo compromiso que un URL prefirmado de S3.
 */
@Component
public class ViewTokenService {

    private static final String ALGORITMO = "HmacSHA256";
    private static final Base64.Encoder ENC = Base64.getUrlEncoder().withoutPadding();
    private static final Base64.Decoder DEC = Base64.getUrlDecoder();

    private final byte[] secreto;
    private final long ttlSegundos;
    private final Clock reloj;

    public ViewTokenService(
            @Value("${files.view-token-secret:}") String secreto,
            @Value("${files.view-token-ttl-seconds:300}") long ttlSegundos) {
        this(secreto, ttlSegundos, Clock.systemUTC());
    }

    /** Constructor de test: reloj inyectable para probar caducidad sin sleep. */
    ViewTokenService(String secreto, long ttlSegundos, Clock reloj) {
        this.secreto = secreto == null ? new byte[0] : secreto.getBytes(StandardCharsets.UTF_8);
        this.ttlSegundos = ttlSegundos;
        this.reloj = reloj;
    }

    /** Vacío = esta puerta está cerrada; falla cerrado, no abierto. */
    public boolean habilitado() {
        return secreto.length > 0;
    }

    public long ttlSegundos() {
        return ttlSegundos;
    }

    /** Acuña un token válido sólo para {@code archivoId}, caduca en {@code ttlSegundos()}. */
    public String acunar(long archivoId) {
        long expira = Instant.now(reloj).getEpochSecond() + ttlSegundos;
        String payload = archivoId + ":" + expira;
        return ENC.encodeToString(payload.getBytes(StandardCharsets.UTF_8)) + "." + firmar(payload);
    }

    /**
     * Valida el token contra el {@code archivoId} pedido. {@code false}
     * si está mal formado, la firma no cuadra, caducó, o es de otro
     * archivo — todos los casos se tratan igual a propósito: cuál fue
     * el motivo exacto sólo le sirve a quien intenta falsificar uno.
     */
    public boolean valido(String token, long archivoId) {
        if (token == null || token.isBlank() || !habilitado()) {
            return false;
        }
        int punto = token.indexOf('.');
        if (punto < 0) {
            return false;
        }
        String payload;
        try {
            payload = new String(DEC.decode(token.substring(0, punto)), StandardCharsets.UTF_8);
        } catch (IllegalArgumentException e) {
            return false;
        }
        String firmaRecibida = token.substring(punto + 1);
        String firmaEsperada = firmar(payload);
        if (!MessageDigest.isEqual(
                firmaEsperada.getBytes(StandardCharsets.UTF_8),
                firmaRecibida.getBytes(StandardCharsets.UTF_8))) {
            return false;
        }
        String[] partes = payload.split(":", 2);
        if (partes.length != 2) {
            return false;
        }
        try {
            long idDelToken = Long.parseLong(partes[0]);
            long expira = Long.parseLong(partes[1]);
            return idDelToken == archivoId && Instant.now(reloj).getEpochSecond() <= expira;
        } catch (NumberFormatException e) {
            return false;
        }
    }

    private String firmar(String payload) {
        try {
            Mac mac = Mac.getInstance(ALGORITMO);
            mac.init(new SecretKeySpec(secreto, ALGORITMO));
            return ENC.encodeToString(mac.doFinal(payload.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException | InvalidKeyException e) {
            // HmacSHA256 es JCE estándar y la clave siempre es no-vacía
            // cuando habilitado() es true; si esto salta es un bug de
            // JVM/config, no una entrada de usuario.
            throw new IllegalStateException("No se pudo firmar el token de vista", e);
        }
    }
}
