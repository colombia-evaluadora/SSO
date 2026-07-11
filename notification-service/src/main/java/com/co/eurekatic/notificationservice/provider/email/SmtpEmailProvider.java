package com.co.eurekatic.notificationservice.provider.email;

import com.co.eurekatic.notificationservice.domain.Channel;
import com.co.eurekatic.notificationservice.domain.RenderedNotification;
import com.co.eurekatic.notificationservice.provider.ChannelProvider;
import com.co.eurekatic.notificationservice.provider.ProviderException;
import com.co.eurekatic.notificationservice.provider.ProviderRegistry;
import jakarta.mail.MessagingException;
import jakarta.mail.internet.MimeMessage;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.mail.javamail.JavaMailSender;
import org.springframework.mail.javamail.JavaMailSenderImpl;
import org.springframework.mail.javamail.MimeMessageHelper;

import java.util.Map;
import java.util.Properties;

/**
 * SMTP email provider. One bean per {@code providerKey}
 * (smtp-brevo, smtp-gmail, smtp-mailhog) — wired by
 * {@link EmailProviderConfig}. Each instance reads its
 * host/port/credentials from {@code provider_config.settings}
 * via {@link ProviderRegistry#settingsFor(String)} on every
 * delivery, so updating the DB row + {@code POST
 * /actuator/providers/refresh} applies new credentials
 * without a restart.
 *
 * <p>Settings JSON shape (see {@code V1__init.sql}):
 * <pre>
 *   host           smtp-relay.brevo.com
 *   port           587
 *   starttls       true
 *   username_env   SMTP_BREVO_USER
 *   password_env   SMTP_BREVO_PASS
 *   from           no-reply@example.com
 * </pre>
 *
 * <p>{@code username_env} / {@code password_env} hold the
 * <em>names</em> of environment variables, not the secrets
 * themselves — credentials never sit in the DB.
 *
 * <p>Both keys are optional — a row with neither (e.g.
 * {@code smtp-mailhog}) targets a relay that needs no
 * authentication at all. When present, both must resolve to a
 * non-blank env value or the row is treated as unconfigured
 * (see {@link #isConfigured()}); AUTH is only attempted when
 * both actually resolve (see {@link #senderFor}).
 */
public class SmtpEmailProvider implements ChannelProvider {

    private static final Logger log = LoggerFactory.getLogger(SmtpEmailProvider.class);

    private final String providerKey;
    private final ProviderRegistry registry;

    private volatile JavaMailSender cachedSender;
    private volatile Map<String, Object> cachedSettings;

    public SmtpEmailProvider(String providerKey, ProviderRegistry registry) {
        this.providerKey = providerKey;
        this.registry = registry;
    }

    @Override
    public String key() { return providerKey; }

    @Override
    public Channel channel() { return Channel.EMAIL; }

    @Override
    public boolean isConfigured() {
        Map<String, Object> settings = registry.settingsFor(providerKey).orElse(Map.of());
        String host = str(settings, "host");
        if (host == null) {
            return false;
        }
        // A row with no username_env/password_env keys (e.g. a dev
        // relay like MailHog) needs no credentials at all. A row that
        // DOES declare them must resolve to a non-blank env value —
        // present-but-empty (Docker Compose's `VAR: ${VAR:-}`) counts
        // as missing, not as "configured with an empty secret".
        String userEnv = str(settings, "username_env");
        String passEnv = str(settings, "password_env");
        if (userEnv == null && passEnv == null) {
            return true;
        }
        return hasText(getenv(userEnv)) && hasText(getenv(passEnv));
    }

    @Override
    public void deliver(RenderedNotification rendered) {
        Map<String, Object> settings = registry.settingsFor(providerKey)
                .orElseThrow(() -> new IllegalStateException(
                        "Provider " + providerKey + " not in roster"));
        JavaMailSender sender = senderFor(settings);
        try {
            MimeMessage mime = sender.createMimeMessage();
            MimeMessageHelper helper = new MimeMessageHelper(mime, false, "UTF-8");
            helper.setFrom(str(settings, "from"));
            helper.setTo(rendered.recipient().address());
            helper.setSubject(rendered.subject());
            helper.setText(rendered.bodyHtml(), true);
            sender.send(mime);
            log.info("[{}] SMTP delivered to {}", providerKey, rendered.recipient().address());
        } catch (MessagingException me) {
            throw new ProviderException("SMTP send failed: " + me.getMessage(), me);
        } catch (RuntimeException ex) {
            throw new ProviderException("SMTP send failed: " + ex.getMessage(), ex);
        }
    }

    private synchronized JavaMailSender senderFor(Map<String, Object> settings) {
        if (cachedSender != null && cachedSettings == settings) {
            return cachedSender;
        }
        JavaMailSenderImpl impl = new JavaMailSenderImpl();
        impl.setHost(str(settings, "host"));
        impl.setPort(intOr(settings, "port", 587));
        // Only set credentials — and only turn AUTH on — when both
        // resolve to a real value. Spring's JavaMailSenderImpl treats an
        // empty-string username as "unset" and substitutes the JVM's OS
        // user instead, which then fails auth against ANY server. A row
        // with no credentials (e.g. a dev relay like MailHog) must skip
        // AUTH entirely rather than attempt it with blanks.
        String user = getenv(str(settings, "username_env"));
        String pass = getenv(str(settings, "password_env"));
        boolean hasAuth = hasText(user) && hasText(pass);
        if (hasAuth) {
            impl.setUsername(user);
            impl.setPassword(pass);
        }
        Properties props = impl.getJavaMailProperties();
        boolean startTls = bool(settings, "starttls");
        props.put("mail.smtp.auth", String.valueOf(hasAuth));
        props.put("mail.smtp.starttls.enable", String.valueOf(startTls));
        props.put("mail.smtp.connectiontimeout", "5000");
        props.put("mail.smtp.timeout", "5000");
        props.put("mail.smtp.writetimeout", "5000");
        cachedSender = impl;
        cachedSettings = settings;
        return impl;
    }

    private static String str(Map<String, Object> m, String k) {
        Object v = m.get(k);
        return v == null ? null : v.toString();
    }

    private static int intOr(Map<String, Object> m, String k, int def) {
        Object v = m.get(k);
        if (v == null) return def;
        if (v instanceof Number n) return n.intValue();
        try { return Integer.parseInt(v.toString()); } catch (NumberFormatException e) { return def; }
    }

    private static boolean bool(Map<String, Object> m, String k) {
        Object v = m.get(k);
        if (v instanceof Boolean b) return b;
        if (v == null) return false;
        return Boolean.parseBoolean(v.toString());
    }

    private static boolean hasText(String s) {
        return s != null && !s.isBlank();
    }

    /** {@code System.getenv} throws NPE on a null name — a row with no
     * {@code username_env}/{@code password_env} key resolves {@code str()}
     * to null, so every lookup here must guard against that. */
    private static String getenv(String name) {
        return name == null ? null : System.getenv(name);
    }
}