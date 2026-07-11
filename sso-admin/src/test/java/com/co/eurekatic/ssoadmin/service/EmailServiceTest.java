package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.common.entity.User;
import com.co.eurekatic.ssoadmin.config.EmailProperties;
import freemarker.template.Configuration;
import freemarker.template.Template;
import jakarta.mail.internet.MimeMessage;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.mail.javamail.JavaMailSender;
import org.springframework.ui.freemarker.FreeMarkerTemplateUtils;

import java.io.StringWriter;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * Verifies that {@link EmailService} populates the Freemarker
 * variables correctly and that mail-send errors are swallowed
 * (don't break the createAccount flow).
 *
 * <p>We mock the Freemarker template's {@code process} method
 * with a {@link StringWriter} rather than
 * {@link FreeMarkerTemplateUtils#processTemplateIntoString} so
 * we can capture the model map directly.
 */
@ExtendWith(MockitoExtension.class)
class EmailServiceTest {

    @Mock JavaMailSender mailSender;
    @Mock Configuration freemarker;
    @Mock Template template;
    @Mock MimeMessage mimeMessage;

    private EmailService service;
    private EmailProperties props;

    @BeforeEach
    void setUp() {
        props = new EmailProperties(
                "no-reply@example.com",
                "Example Inc.",
                "SSO Modernizado",
                "https://example.com/logo.png",
                "http://localhost:8080/admin/activate",
                "http://localhost:8080/admin/restore-password",
                "activation-account.html",
                "restore-password-account.html");
        service = new EmailService(mailSender, freemarker, props);
        // Stubs go inside each test — putting them in setUp would
        // trip UnnecessaryStubbingException for tests that fail
        // before reaching the mailSender (e.g. Freemarker error).
    }

    @Test
    void sendActivationEmailRendersTemplateWithUserAndTokenVars() throws Exception {
        when(freemarker.getTemplate("activation-account.html")).thenReturn(template);
        when(mailSender.createMimeMessage()).thenReturn(mimeMessage);
        // process(Object model, Writer out) — capture both args.
        org.mockito.Mockito.doAnswer(inv -> {
            StringWriter w = inv.getArgument(1);
            w.write("<html>Hello, Alice!</html>");
            return null;
        }).when(template).process(any(), any(StringWriter.class));

        User u = new User();
        u.setFullName("Alice Example");
        u.setEmail("alice@example.com");

        service.sendActivationEmail(u, "tok-abc");

        @SuppressWarnings("unchecked")
        ArgumentCaptor<Map<String, Object>> model = ArgumentCaptor.forClass(Map.class);
        verify(template).process(model.capture(), any(StringWriter.class));
        Map<String, Object> map = model.getValue();
        assertThat(map).containsEntry("userName", "alice@example.com");
        assertThat(map).containsEntry("name", "Alice Example");
        assertThat(map).containsEntry("token", "tok-abc");
        assertThat(map).containsEntry("domain", props.activationUrl());
        assertThat(map).containsEntry("company", "Example Inc.");
        assertThat(map).containsEntry("appName", "SSO Modernizado");
        assertThat(map).containsEntry("logo", "https://example.com/logo.png");

        verify(mailSender).send(mimeMessage);
    }

    @Test
    void sendRestoreEmailUsesRestoreTemplateAndUrl() throws Exception {
        when(freemarker.getTemplate("restore-password-account.html")).thenReturn(template);
        when(mailSender.createMimeMessage()).thenReturn(mimeMessage);
        org.mockito.Mockito.doAnswer(inv -> {
            StringWriter w = inv.getArgument(1);
            w.write("<html>Restore</html>");
            return null;
        }).when(template).process(any(), any(StringWriter.class));

        User u = new User();
        u.setFullName("Alice");
        u.setEmail("alice@example.com");

        service.sendRestorePasswordEmail(u, "rtok");

        // Template + URL distinct from activation flow.
        verify(freemarker).getTemplate("restore-password-account.html");

        @SuppressWarnings("unchecked")
        ArgumentCaptor<Map<String, Object>> model = ArgumentCaptor.forClass(Map.class);
        verify(template).process(model.capture(), any(StringWriter.class));
        assertThat(model.getValue()).containsEntry("token", "rtok");
        assertThat(model.getValue()).containsEntry("domain", props.restoreUrl());
    }

    @Test
    void sendActivationEmailFallsBackToUsernameWhenFullNameNull() throws Exception {
        when(freemarker.getTemplate("activation-account.html")).thenReturn(template);
        when(mailSender.createMimeMessage()).thenReturn(mimeMessage);
        org.mockito.Mockito.doAnswer(inv -> {
            StringWriter w = inv.getArgument(1);
            w.write("<html/>");
            return null;
        }).when(template).process(any(), any(StringWriter.class));

        User u = new User();
        // fullName intentionally null
        u.setEmail("alice@example.com");

        service.sendActivationEmail(u, "tok");

        @SuppressWarnings("unchecked")
        ArgumentCaptor<Map<String, Object>> model = ArgumentCaptor.forClass(Map.class);
        verify(template).process(model.capture(), any(StringWriter.class));
        // "name" should fall back to the email since
        // fullName is null (post-V12 the fallback is the
        // email — the legacy username column is gone).
        assertThat(model.getValue()).containsEntry("name", "alice@example.com");
    }

    @Test
    void sendSwallowsMailerExceptionSoCreateAccountIsNotAffected() throws Exception {
        when(freemarker.getTemplate("activation-account.html")).thenReturn(template);
        org.mockito.Mockito.doAnswer(inv -> {
            throw new RuntimeException("SMTP down");
        }).when(template).process(any(), any(StringWriter.class));
        // No stub for createMimeMessage — the SMTP exception
        // is thrown by Freemarker before we get to the MimeMessage
        // path, so the mailSender.createMimeMessage() stub would
        // be UnnecessaryStubbing.

        User u = new User();
        u.setEmail("alice@example.com");

        // Must NOT propagate — the calling createAccount would
        // otherwise have to deal with a 500 on email failure.
        service.sendActivationEmail(u, "tok");

        // mailSender.send never reached because template rendering failed first.
        verify(mailSender, org.mockito.Mockito.never()).send(any(MimeMessage.class));
    }
}
