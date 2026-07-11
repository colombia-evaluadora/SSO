package com.co.eurekatic.notificationservice.service;

import com.co.eurekatic.notificationservice.domain.Channel;
import com.co.eurekatic.notificationservice.domain.Metadata;
import com.co.eurekatic.notificationservice.domain.NotificationLog;
import com.co.eurekatic.notificationservice.domain.NotificationMessage;
import com.co.eurekatic.notificationservice.domain.NotificationStatus;
import com.co.eurekatic.notificationservice.domain.RenderedNotification;
import com.co.eurekatic.notificationservice.domain.Recipient;
import com.co.eurekatic.notificationservice.provider.ProviderException;
import com.co.eurekatic.notificationservice.repository.NotificationLogRepository;
import com.co.eurekatic.notificationservice.sender.NotificationSender;
import com.co.eurekatic.notificationservice.sender.NotificationSenderRegistry;
import com.co.eurekatic.notificationservice.template.TemplateNotFoundException;
import com.co.eurekatic.notificationservice.template.TemplateRenderer;
import jakarta.validation.ConstraintViolation;
import jakarta.validation.Validator;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.amqp.AmqpRejectAndDontRequeueException;
import org.springframework.dao.DataIntegrityViolationException;

import java.time.Instant;
import java.util.Collections;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * Pure-Mockito unit tests for {@link NotificationProcessor}.
 * No Spring context, no DB, no Rabbit — fast feedback.
 *
 * <p>Covers the 5-step pipeline's edge cases:
 * validation, idempotent insert, render, send, log update.
 */
class NotificationProcessorTest {

    private Validator validator;
    private NotificationLogRepository logRepository;
    private TemplateRenderer renderer;
    private NotificationSenderRegistry senderRegistry;
    private NotificationSender sender;
    private NotificationProcessor processor;

    @BeforeEach
    void setUp() {
        validator = mock(Validator.class);
        logRepository = mock(NotificationLogRepository.class);
        renderer = mock(TemplateRenderer.class);
        senderRegistry = mock(NotificationSenderRegistry.class);
        sender = mock(NotificationSender.class);
        processor = new NotificationProcessor(validator, logRepository, renderer, senderRegistry);
    }

    @Test
    @DisplayName("Invalid message → AmqpRejectAndDontRequeueException, no log row, no send")
    void invalidMessage() {
        NotificationMessage msg = validMessage();
        Set<ConstraintViolation<NotificationMessage>> violations = Set.of(violation("templateId", "must not be blank"));
        when(validator.validate(msg)).thenReturn(violations);

        assertThatThrownBy(() -> processor.process(msg, Channel.EMAIL))
                .isInstanceOf(AmqpRejectAndDontRequeueException.class);

        verify(logRepository, never()).saveAndFlush(any());
        verify(sender, never()).send(any());
    }

    @Test
    @DisplayName("Duplicate notificationId → existing row marked DUPLICATE, no send")
    void duplicateIdempotency() {
        NotificationMessage msg = validMessage();
        when(validator.validate(msg)).thenReturn(Collections.emptySet());
        when(logRepository.saveAndFlush(any(NotificationLog.class)))
                .thenThrow(new DataIntegrityViolationException("dup"));
        NotificationLog existing = new NotificationLog(msg.notificationId(), msg.channel(),
                msg.recipient().userId(), msg.templateId(), NotificationStatus.PENDING);
        when(logRepository.findByNotificationId(msg.notificationId())).thenReturn(Optional.of(existing));

        processor.process(msg, Channel.EMAIL);

        assertThat(existing.getStatus()).isEqualTo(NotificationStatus.DUPLICATE);
        verify(logRepository).save(existing);
        verify(sender, never()).send(any());
    }

    @Test
    @DisplayName("TemplateNotFoundException → log FAILED + AmqpRejectAndDontRequeueException")
    void templateNotFound() {
        NotificationMessage msg = validMessage();
        when(validator.validate(msg)).thenReturn(Collections.emptySet());
        when(logRepository.saveAndFlush(any(NotificationLog.class))).thenAnswer(inv -> inv.getArgument(0));
        when(renderer.render(msg)).thenThrow(new TemplateNotFoundException(msg.templateId(), "EMAIL"));

        assertThatThrownBy(() -> processor.process(msg, Channel.EMAIL))
                .isInstanceOf(AmqpRejectAndDontRequeueException.class);

        ArgumentCaptor<NotificationLog> captor = ArgumentCaptor.forClass(NotificationLog.class);
        verify(logRepository).save(captor.capture());
        assertThat(captor.getValue().getStatus()).isEqualTo(NotificationStatus.FAILED);
        verify(sender, never()).send(any());
    }

    @Test
    @DisplayName("ProviderException → log FAILED + exception bubbles (recoverable → retry)")
    void providerThrows() {
        NotificationMessage msg = validMessage();
        when(validator.validate(msg)).thenReturn(Collections.emptySet());
        when(logRepository.saveAndFlush(any(NotificationLog.class))).thenAnswer(inv -> inv.getArgument(0));
        when(senderRegistry.forChannel(Channel.EMAIL)).thenReturn(sender);
        when(renderer.render(msg)).thenReturn(rendered(msg));
        when(sender.send(any())).thenThrow(new ProviderException("upstream timeout"));

        assertThatThrownBy(() -> processor.process(msg, Channel.EMAIL))
                .isInstanceOf(ProviderException.class);

        ArgumentCaptor<NotificationLog> captor = ArgumentCaptor.forClass(NotificationLog.class);
        verify(logRepository, times(1)).save(captor.capture());
        assertThat(captor.getValue().getStatus()).isEqualTo(NotificationStatus.FAILED);
    }

    @Test
    @DisplayName("Happy path → log SENT with provider key from orchestrator")
    void happyPath() {
        NotificationMessage msg = validMessage();
        when(validator.validate(msg)).thenReturn(Collections.emptySet());
        when(logRepository.saveAndFlush(any(NotificationLog.class))).thenAnswer(inv -> inv.getArgument(0));
        when(senderRegistry.forChannel(Channel.EMAIL)).thenReturn(sender);
        when(renderer.render(msg)).thenReturn(rendered(msg));
        when(sender.send(any())).thenReturn("fake-email");

        processor.process(msg, Channel.EMAIL);

        ArgumentCaptor<NotificationLog> captor = ArgumentCaptor.forClass(NotificationLog.class);
        verify(logRepository).save(captor.capture());
        assertThat(captor.getValue().getStatus()).isEqualTo(NotificationStatus.SENT);
        assertThat(captor.getValue().getProvider()).isEqualTo("fake-email");
    }

    // ---- helpers -------------------------------------------------

    private static NotificationMessage validMessage() {
        return new NotificationMessage(
                UUID.randomUUID(),
                Channel.EMAIL,
                new Recipient("u-1", "user@example.com"),
                "welcome",
                Map.of("displayName", "Ada"),
                new Metadata("test", "corr-1", Instant.now())
        );
    }

    private static RenderedNotification rendered(NotificationMessage msg) {
        return new RenderedNotification(
                msg.channel(),
                "Subject",
                "<html>body</html>",
                null,
                msg.recipient(),
                null,
                java.util.List.of()
        );
    }

    private static <T> ConstraintViolation<T> violation(String path, String message) {
        @SuppressWarnings("unchecked")
        ConstraintViolation<T> v = mock(ConstraintViolation.class);
        jakarta.validation.Path mockPath = mock(jakarta.validation.Path.class);
        when(mockPath.toString()).thenReturn(path);
        when(v.getPropertyPath()).thenReturn(mockPath);
        when(v.getMessage()).thenReturn(message);
        return v;
    }
}