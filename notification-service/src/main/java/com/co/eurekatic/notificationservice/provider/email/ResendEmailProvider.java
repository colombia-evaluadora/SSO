package com.co.eurekatic.notificationservice.provider.email;

import com.co.eurekatic.notificationservice.domain.Channel;
import com.co.eurekatic.notificationservice.domain.RenderedNotification;
import com.co.eurekatic.notificationservice.provider.ChannelProvider;
import com.co.eurekatic.notificationservice.provider.ProviderException;
import com.co.eurekatic.notificationservice.provider.ProviderRegistry;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.web.client.RestClient;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Resend email provider. Hits
 * {@code POST https://api.resend.com/emails} with a Bearer
 * token from {@code RESEND_API_KEY}.
 *
 * <p>The settings JSON on the row is allowed to override
 * the default {@code api_base} for tests
 * ({@code http://localhost:<mockPort>}). In dev / staging
 * the operator typically keeps the default.
 */
public class ResendEmailProvider implements ChannelProvider {

    private static final Logger log = LoggerFactory.getLogger(ResendEmailProvider.class);

    private static final String API_KEY_ENV = "RESEND_API_KEY";

    private final ProviderRegistry registry;
    private volatile RestClient cachedClient;
    private volatile Map<String, Object> cachedSettings;

    public ResendEmailProvider(ProviderRegistry registry) {
        this.registry = registry;
    }

    @Override
    public String key() { return "resend"; }

    @Override
    public Channel channel() { return Channel.EMAIL; }

    @Override
    public boolean isConfigured() {
        return System.getenv(API_KEY_ENV) != null;
    }

    @Override
    public void deliver(RenderedNotification rendered) {
        Map<String, Object> settings = registry.settingsFor("resend").orElse(Map.of());
        RestClient client = clientFor(settings);
        String from = str(settings, "from");
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("from", from);
        body.put("to", List.of(rendered.recipient().address()));
        body.put("subject", rendered.subject());
        body.put("html", rendered.bodyHtml());
        try {
            client.post()
                    .uri("/emails")
                    .body(body)
                    .retrieve()
                    .toBodilessEntity();
            log.info("[resend] delivered to {}", rendered.recipient().address());
        } catch (RuntimeException ex) {
            throw new ProviderException("Resend send failed: " + ex.getMessage(), ex);
        }
    }

    private synchronized RestClient clientFor(Map<String, Object> settings) {
        if (cachedClient != null && cachedSettings == settings) {
            return cachedClient;
        }
        String baseUrl = str(settings, "api_base");
        if (baseUrl == null) baseUrl = "https://api.resend.com";
        String apiKey = System.getenv(API_KEY_ENV);
        cachedClient = RestClient.builder()
                .baseUrl(baseUrl)
                .defaultHeader(HttpHeaders.AUTHORIZATION, "Bearer " + apiKey)
                .defaultHeader(HttpHeaders.CONTENT_TYPE, MediaType.APPLICATION_JSON_VALUE)
                .build();
        cachedSettings = settings;
        return cachedClient;
    }

    private static String str(Map<String, Object> m, String k) {
        Object v = m.get(k);
        return v == null ? null : v.toString();
    }
}