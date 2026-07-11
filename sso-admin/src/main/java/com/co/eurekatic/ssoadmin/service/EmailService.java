package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.common.entity.User;
import com.co.eurekatic.ssoadmin.config.EmailProperties;
import freemarker.template.Configuration;
import freemarker.template.Template;
import jakarta.mail.MessagingException;
import jakarta.mail.internet.MimeMessage;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.mail.javamail.JavaMailSender;
import org.springframework.mail.javamail.MimeMessageHelper;
import org.springframework.stereotype.Service;
import org.springframework.ui.freemarker.FreeMarkerTemplateUtils;

import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;

/**
 * Renders Freemarker templates and sends them via
 * {@link JavaMailSender}. The legacy used
 * {@code com.co.lowcode.sso.config.SmtpMailSender} with
 * hardcoded Gmail credentials — this version reads SMTP
 * configuration from {@code spring.mail.*} (env-driven) and the
 * templates' variables from {@link EmailProperties}.
 */
@Service
public class EmailService {

    private static final Logger log = LoggerFactory.getLogger(EmailService.class);

    private final JavaMailSender mailSender;
    private final Configuration freemarker;
    private final EmailProperties props;

    public EmailService(JavaMailSender mailSender,
                        Configuration freemarker,
                        EmailProperties props) {
        this.mailSender = mailSender;
        this.freemarker = freemarker;
        this.props = props;
    }

    /**
     * Sends the activation email. The {@code token} is what
     * the user clicks on to land on {@code /activateAccount}.
     */
    public void sendActivationEmail(User user, String token) {
        Map<String, Object> vars = baseVars(user);
        vars.put("token", token);
        vars.put("domain", props.activationUrl());
        send(props.activationTemplate(),
                user.getEmail(),
                "Activación de Cuenta " + props.company(),
                vars);
    }

    /**
     * Sends the restore-password email.
     */
    public void sendRestorePasswordEmail(User user, String token) {
        Map<String, Object> vars = baseVars(user);
        vars.put("token", token);
        vars.put("domain", props.restoreUrl());
        send(props.restoreTemplate(),
                user.getEmail(),
                "Cambio de Contraseña de Cuenta",
                vars);
    }

    private Map<String, Object> baseVars(User user) {
        Map<String, Object> vars = new HashMap<>();
        // The {@code userName} var used to be {@code user.getUsername()}.
        // That column is gone since V12 — email IS the login identifier
        // now, so we expose it as the visible "user" reference for the
        // email template (the legacy template label rendered it as
        // "Tu nombre de usuario:"). Templates that want the full name
        // use {@code name}.
        vars.put("userName", user.getEmail());
        vars.put("email", user.getEmail());
        vars.put("name", user.getFullName() == null ? user.getEmail() : user.getFullName());
        vars.put("logo", props.logoUrl());
        vars.put("company", props.company());
        vars.put("appName", props.appName());
        return vars;
    }

    private void send(String templateName, String to, String subject, Map<String, Object> vars) {
        try {
            Template template = freemarker.getTemplate(templateName);
            String html = FreeMarkerTemplateUtils.processTemplateIntoString(template, vars);

            MimeMessage message = mailSender.createMimeMessage();
            MimeMessageHelper helper = new MimeMessageHelper(
                    message, false, StandardCharsets.UTF_8.name());
            helper.setFrom(props.from());
            helper.setTo(to);
            helper.setSubject(subject);
            helper.setText(html, true);

            mailSender.send(message);
            log.info("Sent email to {} (template={}, subject={})", to, templateName, subject);
        } catch (Exception e) {
            // Don't fail the whole createAccount flow on an email
            // error — the user is created in the DB and the admin
            // can resend. Log loudly so it's debuggable.
            log.error("Failed to send email to {} (template={})", to, templateName, e);
        }
    }
}
