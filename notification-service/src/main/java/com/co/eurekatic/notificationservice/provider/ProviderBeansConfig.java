package com.co.eurekatic.notificationservice.provider;

import com.co.eurekatic.notificationservice.provider.email.EmailJsProvider;
import com.co.eurekatic.notificationservice.provider.email.ResendEmailProvider;
import com.co.eurekatic.notificationservice.provider.push.FcmPushProvider;
import com.co.eurekatic.notificationservice.provider.sms.TwilioSmsProvider;
import com.co.eurekatic.notificationservice.provider.sms.VonageSmsProvider;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Lazy;

/**
 * Wires every non-SMTP {@link ChannelProvider} as a Spring
 * bean. (SMTP is wired by {@link com.co.eurekatic.notificationservice.provider.email.EmailProviderConfig}
 * because it ships with two instances out of the box.)
 *
 * <p>Each provider's {@link ChannelProvider#isConfigured()}
 * returns false when its required env vars are missing —
 * the registry excludes it from the roster with a WARN, no
 * startup crash. Enabling a provider therefore takes two
 * steps in production:
 * <ol>
 *   <li>{@code UPDATE provider_config SET enabled = TRUE WHERE provider_key = '<key>';}</li>
 *   <li>{@code POST /actuator/providers/refresh}</li>
 * </ol>
 */
@Configuration
public class ProviderBeansConfig {

    @Bean(name = "twilio")
    public ChannelProvider twilioSmsProvider() {
        return new TwilioSmsProvider();
    }

    @Bean(name = "vonage")
    public ChannelProvider vonageSmsProvider() {
        return new VonageSmsProvider();
    }

    @Bean(name = "fcm")
    public ChannelProvider fcmPushProvider(@Lazy ProviderRegistry registry) {
        return new FcmPushProvider(registry);
    }

    @Bean(name = "resend")
    public ChannelProvider resendEmailProvider(@Lazy ProviderRegistry registry) {
        return new ResendEmailProvider(registry);
    }

    @Bean(name = "emailjs")
    public ChannelProvider emailJsProvider(@Lazy ProviderRegistry registry) {
        return new EmailJsProvider(registry);
    }
}