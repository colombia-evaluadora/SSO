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
import java.util.Map;

/**
 * EmailJS passthrough provider. EmailJS doesn't render
 * templates server-side — the operator defines the
 * template in the EmailJS dashboard and passes a JSON
 * payload via the {@code template_params} field. We use
 * a single template id ({@code passthrough}, configurable
 * via the settings JSON) and shove the rendered HTML body
 * into {@code template_params.html_body} so the EmailJS
 * template can drop it in with a {@code {{{html_body}}}}
 * triple-mustache expression.
 *
 * <p>Required env vars (resolved from the settings JSON
 * {@code *_env} keys):
 * <ul>
 *   <li>{@code EMAILJS_SERVICE_ID}</li>
 *   <li>{@code EMAILJS_PUBLIC_KEY}</li>
 *   <li>{@code EMAILJS_PRIVATE_KEY}</li>
 * </ul>
 */
public class EmailJsProvider implements ChannelProvider {

    private static final Logger log = LoggerFactory.getLogger(EmailJsProvider.class);

    private final ProviderRegistry registry;
    private volatile RestClient cachedClient;
    private volatile Map<String, Object> cachedSettings;

    public EmailJsProvider(ProviderRegistry registry) {
        this.registry = registry;
    }

    @Override
    public String key() { return "emailjs"; }

    @Override
    public Channel channel() { return Channel.EMAIL; }

    @Override
    public boolean isConfigured() {
        Map<String, Object> settings = registry.settingsFor("emailjs").orElse(Map.of());
        return env(settings, "service_id_env") != null
                && env(settings, "public_key_env") != null
                && env(settings, "private_key_env") != null;
    }

    @Override
    public void deliver(RenderedNotification rendered) {
        Map<String, Object> settings = registry.settingsFor("emailjs").orElse(Map.of());
        RestClient client = clientFor(settings);
        Map<String, Object> templateParams = new LinkedHashMap<>();
        templateParams.put("to_email", rendered.recipient().address());
        templateParams.put("subject", rendered.subject());
        templateParams.put("html_body", rendered.bodyHtml());
        templateParams.put("from_name", str(settings, "from"));

        Map<String, Object> body = new LinkedHashMap<>();
        body.put("service_id", env(settings, "service_id_env"));
        body.put("template_id", str(settings, "template_id"));
        body.put("user_id", env(settings, "public_key_env"));
        body.put("accessToken", env(settings, "private_key_env"));
        body.put("template_params", templateParams);

        try {
            client.post()
                    .body(body)
                    .retrieve()
                    .toBodilessEntity();
            log.info("[emailjs] delivered to {}", rendered.recipient().address());
        } catch (RuntimeException ex) {
            throw new ProviderException("EmailJS send failed: " + ex.getMessage(), ex);
        }
    }

    private synchronized RestClient clientFor(Map<String, Object> settings) {
        if (cachedClient != null && cachedSettings == settings) {
            return cachedClient;
        }
        String baseUrl = str(settings, "api_base");
        if (baseUrl == null) baseUrl = "https://api.emailjs.com/api/v1.0/email/send";
        cachedClient = RestClient.builder()
                .baseUrl(baseUrl)
                .defaultHeader(HttpHeaders.CONTENT_TYPE, MediaType.APPLICATION_JSON_VALUE)
                .build();
        cachedSettings = settings;
        return cachedClient;
    }

    private static String str(Map<String, Object> m, String k) {
        Object v = m.get(k);
        return v == null ? null : v.toString();
    }

    private static String env(Map<String, Object> m, String k) {
        String name = str(m, k);
        return name == null ? null : System.getenv(name);
    }
}