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
}