package com.co.eurekatic.notificationservice.push;

import com.co.eurekatic.notificationservice.domain.Channel;
import com.co.eurekatic.notificationservice.domain.RenderedNotification;
import com.co.eurekatic.notificationservice.provider.ChannelProvider;
import com.co.eurekatic.notificationservice.provider.ProviderException;
import com.co.eurekatic.notificationservice.push.PushSuscripcionRepository.Destino;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.interfaces.ECPrivateKey;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Proveedor PUSH {@code webpush} (impl {@code WEBPUSH}): Web Push estandar con
 * claves VAPID propias, sin Firebase ni SDK de terceros (OpenSpec
 * add-notificaciones-push-webpush D-4.1).
 *
 * <p>El destinatario es el usuario ({@code recipient.address = "webpush:<sub>"}):
 * se entrega a todas sus suscripciones activas. El cuerpo es el texto ya
 * renderizado de {@code templates/push/notificacion.txt}, un JSON minimo sin
 * datos personales (D-4.2). Respuesta 404/410 invalida la suscripcion y no se
 * reintenta; 429/5xx/red se propagan como {@link ProviderException} para que la
 * cola reintente (D-4.3), solo si ningun dispositivo recibio el mensaje.
 */
@Component
public class WebPushProvider implements ChannelProvider {

    public static final String PREFIJO_DESTINATARIO = "webpush:";

    private static final Logger log = LoggerFactory.getLogger(WebPushProvider.class);
    private static final Duration VIDA_JWT = Duration.ofHours(12);

    private final VapidClaves claves;
    private final PushSuscripcionRepository suscripciones;
    private final HttpClient http;
    private final Duration timeout;
    private final Map<String, CachedJwt> jwtPorAudiencia = new ConcurrentHashMap<>();

    private record CachedJwt(String token, Instant expira) { }

    public WebPushProvider(VapidClaves claves, PushSuscripcionRepository suscripciones,
                           @Value("${NOTIFICATION_HTTP_CONNECT_TIMEOUT:3s}") Duration connectTimeout,
                           @Value("${NOTIFICATION_HTTP_READ_TIMEOUT:10s}") Duration readTimeout) {
        this.claves = claves;
        this.suscripciones = suscripciones;
        this.http = HttpClient.newBuilder().connectTimeout(connectTimeout)
                .followRedirects(HttpClient.Redirect.NEVER).build();
        this.timeout = readTimeout;
    }

    @Override
    public String key() {
        return VapidClaves.KEY;
    }

    @Override
    public Channel channel() {
        return Channel.PUSH;
    }

    @Override
    public boolean isConfigured() {
        return claves.configuradas();
    }

    /** Solo atiende destinatarios {@code webpush:<sub>}; los tokens FCM siguen a su proveedor. */
    public static boolean atiende(RenderedNotification rendered) {
        return rendered.recipient() != null && rendered.recipient().address() != null
                && rendered.recipient().address().startsWith(PREFIJO_DESTINATARIO);
    }

    @Override
    public void deliver(RenderedNotification rendered) {
        if (!atiende(rendered)) {
            throw new ProviderException("webpush solo entrega a destinatarios " + PREFIJO_DESTINATARIO + "<sub>");
        }
        String usuario = rendered.recipient().address().substring(PREFIJO_DESTINATARIO.length());
        List<Destino> destinos = suscripciones.destinos(usuario);
        if (destinos.isEmpty()) {
            log.debug("Usuario sin suscripciones push activas, nada que enviar");
            return;
        }
        byte[] payload = rendered.bodyText().getBytes(StandardCharsets.UTF_8);
        int entregados = 0;
        ProviderException ultimo = null;
        for (Destino d : destinos) {
            try {
                if (enviar(d, payload)) entregados++;
            } catch (ProviderException e) {
                ultimo = e;
            }
        }
        if (entregados == 0 && ultimo != null) throw ultimo;
    }

    /** @return true si el push service acepto el mensaje. */
    boolean enviar(Destino d, byte[] payload) {
        URI endpoint = URI.create(d.endpoint());
        HttpRequest request;
        try {
            byte[] cuerpo = WebPushCrypto.cifrar(payload, WebPushCrypto.b64(d.p256dh()), WebPushCrypto.b64(d.auth()));
            request = HttpRequest.newBuilder(endpoint)
                    .timeout(timeout)
                    .header("TTL", String.valueOf(claves.ttlSegundos()))
                    .header("Urgency", "normal")
                    .header("Content-Encoding", "aes128gcm")
                    .header("Content-Type", "application/octet-stream")
                    .header("Authorization", "vapid t=" + jwt(endpoint) + ", k=" + claves.publica().orElseThrow())
                    .POST(HttpRequest.BodyPublishers.ofByteArray(cuerpo))
                    .build();
        } catch (GeneralSecurityException | IllegalArgumentException e) {
            // Claves de la suscripcion corruptas: no tiene arreglo reintentando.
            log.warn("Suscripcion push {} con claves invalidas, se invalida: {}", d.id(), e.getMessage());
            suscripciones.invalidar(d.id());
            return false;
        }
        HttpResponse<String> resp;
        try {
            resp = http.send(request, HttpResponse.BodyHandlers.ofString());
        } catch (IOException e) {
            throw new ProviderException("Push service inalcanzable: " + e.getMessage(), e);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new ProviderException("Envio push interrumpido", e);
        }
        int status = resp.statusCode();
        if (status >= 200 && status < 300) {
            suscripciones.marcarUso(d.id());
            return true;
        }
        if (status == 404 || status == 410) {
            suscripciones.invalidar(d.id());
            return false;
        }
        if (status == 429 || status >= 500) {
            throw new ProviderException("Push service respondio " + status
                    + resp.headers().firstValue("Retry-After").map(r -> " (Retry-After " + r + ")").orElse(""));
        }
        // 400/403/413: mensaje o VAPID mal formados; reintentar no lo arregla.
        log.warn("Push service rechazo el envio a la suscripcion {} con {}: {}", d.id(), status, resp.body());
        return false;
    }

    private String jwt(URI endpoint) throws GeneralSecurityException {
        String audiencia = endpoint.getScheme() + "://" + endpoint.getHost()
                + (endpoint.getPort() > 0 ? ":" + endpoint.getPort() : "");
        Instant ahora = Instant.now();
        CachedJwt c = jwtPorAudiencia.get(audiencia);
        if (c != null && c.expira().isAfter(ahora.plus(Duration.ofMinutes(30)))) return c.token();
        ECPrivateKey clave = WebPushCrypto.privateKey(WebPushCrypto.b64(claves.privada().orElseThrow()));
        Instant expira = ahora.plus(VIDA_JWT);
        String token = WebPushCrypto.vapidJwt(audiencia, claves.subject().orElseThrow(), expira.getEpochSecond(), clave);
        jwtPorAudiencia.put(audiencia, new CachedJwt(token, expira));
        return token;
    }
}
