package com.co.eurekatic.notificationservice.provider.email;

import com.co.eurekatic.notificationservice.provider.ChannelProvider;
import com.co.eurekatic.notificationservice.provider.ProviderRegistry;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Lazy;

/**
 * Wires one {@link SmtpEmailProvider} bean per SMTP-enabled
 * row in {@code provider_config} — the seed (see
 * {@code V1__init.sql}) ships with {@code smtp-brevo}
 * enabled and {@code smtp-gmail} disabled by default;
 * enabling the Gmail row in the DB then refreshing
 * {@code /actuator/providers} is enough to make it live,
 * no bean edit needed.
 *
 * <p><b>These beans are legacy, not required anymore.</b>
 * {@link ProviderRegistry#refresh()} now builds a {@link
 * SmtpEmailProvider} on the fly for any {@code impl = SMTP} row that
 * has no matching bean here — a NEW account (e.g. a third app's
 * ZeptoMail token) only needs an INSERT into {@code provider_config}
 * + its env vars + the {@code docker-compose.yml} wiring, no Java
 * change or redeploy. The four beans below stay only because they
 * already existed before that fallback was added; nothing breaks by
 * removing them (the dynamic path would just pick them up instead),
 * but there's no reason to churn a working bean either.
 *
 * <p>{@code smtp-mailhog} (see {@code V2__seed_smtp_mailhog.sql})
 * is the dev-visibility fallback: no {@code username_env}/
 * {@code password_env} in its settings, so it needs no
 * credentials and is always {@link SmtpEmailProvider#isConfigured()
 * configured}. Its priority sits below the real providers and
 * above the {@code fake-email} row, so it only wins when
 * smtp-brevo/smtp-gmail self-disable for missing credentials —
 * in production, setting real credentials makes those win again
 * without touching this bean.
 *
 * <p>The provider key is the {@code providerKey} in the
 * {@code provider_config} table. The {@link ChannelProvider}
 * interface contract ties each key to its row at runtime.
 *
 * <p>{@code @Lazy} on the registry parameter breaks the
 * bean-wiring cycle: {@code ProviderRegistry} needs
 * {@code List<ChannelProvider>} (incl. these SMTP
 * beans) in its ctor, while {@code SmtpEmailProvider}
 * needs {@code ProviderRegistry} in its ctor. Spring
 * constructs the registry first with a lazy proxy for
 * the providers; actual {@code registry.settingsFor(...)}
 * calls are made at deliver-time, long after both
 * beans are fully wired.
 */
@Configuration
public class EmailProviderConfig {

    @Bean(name = "smtp-brevo")
    public ChannelProvider smtpBrevo(@Lazy ProviderRegistry registry) {
        return new SmtpEmailProvider("smtp-brevo", registry);
    }

    @Bean(name = "smtp-gmail")
    public ChannelProvider smtpGmail(@Lazy ProviderRegistry registry) {
        return new SmtpEmailProvider("smtp-gmail", registry);
    }

    @Bean(name = "smtp-mailhog")
    public ChannelProvider smtpMailhog(@Lazy ProviderRegistry registry) {
        return new SmtpEmailProvider("smtp-mailhog", registry);
    }

    /**
     * ZeptoMail (Zoho), sembrado por {@code V3__seed_smtp_zeptomail.sql}.
     * El usuario SMTP es la cadena literal {@code emailapikey} para todas
     * las cuentas — lo que identifica la cuenta es la contraseña, que es
     * el token. No es una errata en el {@code .env}.
     *
     * <p>Este bean sigue existiendo por historia, no por necesidad: desde
     * que {@link ProviderRegistry#dynamicSmtpProvider} existe, una fila
     * {@code impl = SMTP} sin bean ya no se descarta — se construye sola.
     * Ver el {@code smtp-zeptomail-pigse} sembrado por V4, que nunca tuvo
     * uno.
     */
    @Bean(name = "smtp-zeptomail")
    public ChannelProvider smtpZeptomail(@Lazy ProviderRegistry registry) {
        return new SmtpEmailProvider("smtp-zeptomail", registry);
    }

    // `smtp-zeptomail-pigse` (V4__provider_config_per_app.sql, app_name =
    // 'PIGSE') deliberately has NO bean here — it's the first row that
    // proves `ProviderRegistry.dynamicSmtpProvider()` works: enabling it
    // in the DB + its env vars + docker-compose is enough, no bean/redeploy.
}