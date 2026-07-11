package com.co.eurekatic.notificationservice.provider.push;

import com.co.eurekatic.notificationservice.domain.Channel;
import com.co.eurekatic.notificationservice.domain.RenderedNotification;
import com.co.eurekatic.notificationservice.provider.ChannelProvider;
import com.co.eurekatic.notificationservice.provider.ProviderException;
import com.co.eurekatic.notificationservice.provider.ProviderRegistry;
import com.google.auth.oauth2.GoogleCredentials;
import com.google.firebase.FirebaseApp;
import com.google.firebase.FirebaseOptions;
import com.google.firebase.messaging.FirebaseMessaging;
import com.google.firebase.messaging.FirebaseMessagingException;
import com.google.firebase.messaging.Message;
import com.google.firebase.messaging.Notification;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.FileInputStream;
import java.io.IOException;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Firebase Cloud Messaging (FCM) push provider.
 *
 * <p>Credentials live in a service-account JSON key file
 * referenced by the {@code GOOGLE_APPLICATION_CREDENTIALS}
 * env var. The provider initialises {@link FirebaseApp}
 * once on first use; subsequent deliveries reuse the
 * singleton {@link FirebaseMessaging} handle.
 *
 * <p>Recipient address is the device registration token.
 */
public class FcmPushProvider implements ChannelProvider {

    private static final Logger log = LoggerFactory.getLogger(FcmPushProvider.class);

    private static final String CREDENTIALS_ENV = "GOOGLE_APPLICATION_CREDENTIALS";

    private final ProviderRegistry registry;
    private final AtomicReference<FirebaseMessaging> messaging = new AtomicReference<>();

    public FcmPushProvider(ProviderRegistry registry) {
        this.registry = registry;
    }

    @Override
    public String key() { return "fcm"; }

    @Override
    public Channel channel() { return Channel.PUSH; }

    @Override
    public boolean isConfigured() {
        // The settings row may carry a credentials_env override
        // for tests; default to the standard env var.
        Map<String, Object> settings = registry.settingsFor("fcm").orElse(Map.of());
        String envName = (String) settings.getOrDefault("credentials_env", CREDENTIALS_ENV);
        return System.getenv(envName) != null;
    }

    @Override
    public void deliver(RenderedNotification rendered) {
        FirebaseMessaging fm = messaging.updateAndGet(existing -> existing != null ? existing : init());
        try {
            Message message = Message.builder()
                    .setToken(rendered.recipient().address())
                    .setNotification(Notification.builder()
                            .setTitle("Notification")
                            .setBody(rendered.bodyText())
                            .build())
                    .build();
            String response = fm.send(message);
            log.debug("FCM delivered: {}", response);
        } catch (FirebaseMessagingException fme) {
            throw new ProviderException("FCM send failed: " + fme.getErrorCode() + " " + fme.getMessage(), fme);
        } catch (RuntimeException ex) {
            throw new ProviderException("FCM send failed: " + ex.getMessage(), ex);
        }
    }

    private FirebaseMessaging init() {
        String envName = registry.settingsFor("fcm")
                .map(s -> (String) s.getOrDefault("credentials_env", CREDENTIALS_ENV))
                .orElse(CREDENTIALS_ENV);
        String credsPath = System.getenv(envName);
        if (credsPath == null) {
            throw new IllegalStateException("Missing " + envName);
        }
        try (FileInputStream fis = new FileInputStream(credsPath)) {
            FirebaseOptions options = FirebaseOptions.builder()
                    .setCredentials(GoogleCredentials.fromStream(fis))
                    .build();
            FirebaseApp app = FirebaseApp.getApps().isEmpty()
                    ? FirebaseApp.initializeApp(options)
                    : FirebaseApp.getInstance();
            return FirebaseMessaging.getInstance(app);
        } catch (IOException ioe) {
            throw new IllegalStateException("Failed to load FCM credentials: " + ioe.getMessage(), ioe);
        }
    }
}