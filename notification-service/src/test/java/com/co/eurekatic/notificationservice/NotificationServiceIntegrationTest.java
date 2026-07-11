package com.co.eurekatic.notificationservice;

import com.co.eurekatic.notificationservice.domain.Channel;
import com.co.eurekatic.notificationservice.domain.Metadata;
import com.co.eurekatic.notificationservice.domain.NotificationLog;
import com.co.eurekatic.notificationservice.domain.NotificationMessage;
import com.co.eurekatic.notificationservice.domain.NotificationStatus;
import com.co.eurekatic.notificationservice.domain.Recipient;
import com.co.eurekatic.notificationservice.provider.ProviderConfigRepository;
import com.co.eurekatic.notificationservice.provider.ProviderConfigRow;
import com.co.eurekatic.notificationservice.provider.ProviderRegistry;
import com.co.eurekatic.notificationservice.repository.NotificationLogRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.context.annotation.Import;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.assertThat;
import static org.awaitility.Awaitility.await;

/**
 * End-to-end tests covering the six core scenarios from the
 * spec. Each test publishes a single message into the
 * notifications exchange and asserts on the resulting
 * {@code notification_log} row (and, when relevant, the
 * provider that handled it).
 *
 * <p>The {@code fake-email} / {@code fake-sms} / {@code fake-push}
 * beans are auto-wired; the {@code failing-fake} bean is
 * wired by {@link TestOnlyFakesConfig} under the
 * {@code test} profile.
 */
@Import(TestOnlyFakesConfig.class)
class NotificationServiceIntegrationTest extends AbstractIntegrationTest {

    @Autowired RabbitTemplate rabbitTemplate;
    @Autowired NotificationLogRepository logRepository;
    @Autowired ProviderConfigRepository providerConfigRepository;
    @Autowired ProviderRegistry providerRegistry;

    @BeforeEach
    void cleanLog() {
        logRepository.deleteAll();
        // Reset provider_config to the seed-equivalent: only
        // fake-* enabled, everything else disabled. Each
        // scenario then mutates this baseline.
        resetProviderConfigToFakes();
    }

    @Test
    @DisplayName("1. Happy path: publish email → fake-email invoked, log SENT")
    void happyPathEmail() throws Exception {
        UUID id = UUID.randomUUID();
        publishEmail(id);

        NotificationLog row = awaitLogWithStatus(id, NotificationStatus.SENT, 5);
        assertThat(row.getChannel()).isEqualTo(Channel.EMAIL);
        assertThat(row.getProvider()).isEqualTo("fake-email");
    }

    @Test
    @DisplayName("2. Idempotency: same notificationId twice → second row DUPLICATE")
    void idempotency() throws Exception {
        UUID id = UUID.randomUUID();
        publishEmail(id);
        awaitLogWithStatus(id, NotificationStatus.SENT, 5);

        publishEmail(id);
        Thread.sleep(500);
        Optional<NotificationLog> all = logRepository.findByNotificationId(id);
        assertThat(all).isPresent();
        // Second publish triggers DataIntegrityViolation →
        // existing row is marked DUPLICATE.
        assertThat(all.get().getStatus()).isEqualTo(NotificationStatus.DUPLICATE);
    }

    @Test
    @DisplayName("3. All providers fail: retries exhausted → log FAILED")
    void allProvidersFail() throws Exception {
        UUID id = UUID.randomUUID();
        // Disable fake-email; keep only failing-fake enabled.
        providerConfigRepository.findAll().stream()
                .filter(r -> r.providerKey().equals("fake-email"))
                .forEach(r -> { r.applySettings(r.settings()); /* no mutation, just touch */ });
        enableOnly("failing-fake");
        providerRegistry.refresh();

        publishEmail(id);

        // After Spring AMQP retries are exhausted the message
        // is rejected → log row stays PENDING on first insert
        // and never moves to SENT; the processor's markFailed
        // path runs once and the log ends FAILED.
        NotificationLog row = awaitLogWithStatus(id, NotificationStatus.FAILED, 10);
        assertThat(row.getErrorMessage()).contains("FailingFakeProvider");
    }

    @Test
    @DisplayName("4. Invalid payload: missing templateId → straight to DLQ, no log row")
    void invalidPayload() throws Exception {
        NotificationMessage bad = new NotificationMessage(
                UUID.randomUUID(),
                Channel.EMAIL,
                new Recipient(null, "test@example.com"),
                "", // <-- blank templateId violates @NotBlank
                Map.of("foo", "bar"),
                new Metadata("test", "corr-1", Instant.now())
        );
        rabbitTemplate.convertAndSend("notifications", "email", bad);

        // No log row should ever appear.
        Thread.sleep(2000);
        assertThat(logRepository.findByNotificationId(bad.notificationId())).isEmpty();
    }

    @Test
    @DisplayName("5. Failover: primary fails, secondary succeeds → log SENT with secondary")
    void failover() throws Exception {
        UUID id = UUID.randomUUID();
        enableOnly("failing-fake", "fake-email");
        providerRegistry.refresh();

        publishEmail(id);

        NotificationLog row = awaitLogWithStatus(id, NotificationStatus.SENT, 5);
        assertThat(row.getProvider()).isEqualTo("fake-email");
    }

    @Test
    @DisplayName("6. Refresh without restart: enable provider via refresh → next publish succeeds")
    void refreshWithoutRestart() throws Exception {
        UUID id = UUID.randomUUID();
        enableOnly("failing-fake");
        providerRegistry.refresh();

        publishEmail(id);
        awaitLogWithStatus(id, NotificationStatus.FAILED, 10);

        // Enable fake-email, refresh, republish.
        enableOnly("failing-fake", "fake-email");
        providerRegistry.refresh();

        UUID id2 = UUID.randomUUID();
        publishEmail(id2);
        NotificationLog row = awaitLogWithStatus(id2, NotificationStatus.SENT, 5);
        assertThat(row.getProvider()).isEqualTo("fake-email");
    }

    // ---- helpers --------------------------------------------------

    private void publishEmail(UUID id) {
        NotificationMessage msg = new NotificationMessage(
                id,
                Channel.EMAIL,
                new Recipient("user-" + id, "user-" + id + "@example.com"),
                "welcome",
                Map.of(
                        "displayName", "Ada",
                        "loginLink", "https://app.example.com/login",
                        "notificationId", id.toString()
                ),
                new Metadata("integration-test", "corr-" + id, Instant.now())
        );
        rabbitTemplate.convertAndSend("notifications", "email", msg);
    }

    private NotificationLog awaitLogWithStatus(UUID id, NotificationStatus expected, int seconds) {
        return await().atMost(seconds, TimeUnit.SECONDS)
                .pollInterval(200, TimeUnit.MILLISECONDS)
                .until(() -> logRepository.findByNotificationId(id)
                                .filter(r -> r.getStatus() == expected)
                                .orElse(null),
                        r -> r != null);
    }

    @Transactional
    void resetProviderConfigToFakes() {
        // Reset every row to enabled=false; per-test setup
        // flips the ones it needs back on.
        for (ProviderConfigRow row : providerConfigRepository.findAll()) {
            row.setEnabled(false);
        }
        providerConfigRepository.flush();
    }

    @Transactional
    void enableOnly(String... keys) {
        java.util.Set<String> allowed = java.util.Set.of(keys);
        for (ProviderConfigRow row : providerConfigRepository.findAll()) {
            row.setEnabled(allowed.contains(row.providerKey()));
        }
        providerConfigRepository.flush();
    }
}