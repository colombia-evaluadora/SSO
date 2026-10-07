package com.co.eurekatic.notificationservice.template;

import org.junit.jupiter.api.Test;
import org.thymeleaf.context.Context;
import org.thymeleaf.spring6.SpringTemplateEngine;
import org.thymeleaf.templatemode.TemplateMode;
import org.thymeleaf.templateresolver.ClassLoaderTemplateResolver;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Renderiza de verdad {@code email/account-activation.html} con el mismo
 * motor (Thymeleaf + SpEL) que usa {@link TemplateRenderer}.
 *
 * <p>La invitacion dura 7 dias ({@code TokenService.ACTIVATION_TTL_MINUTES}
 * en sso-admin = 10080). La plantilla convierte {@code ttlMinutes} a dias
 * cuando es multiplo exacto de 1440; si la expresion se rompe, el correo
 * sale sin plazo o con "10080 minutos" y nadie se entera.
 */
class AccountActivationTemplateTest {

    private static String render(Object ttlMinutes) {
        ClassLoaderTemplateResolver resolver = new ClassLoaderTemplateResolver();
        resolver.setPrefix("templates/");
        resolver.setSuffix(".html");
        resolver.setTemplateMode(TemplateMode.HTML);
        resolver.setCharacterEncoding("UTF-8");
        SpringTemplateEngine engine = new SpringTemplateEngine();
        engine.setTemplateResolver(resolver);

        Context ctx = new Context();
        ctx.setVariable("displayName", "Ana Perez");
        ctx.setVariable("email", "ana@example.com");
        ctx.setVariable("activationLink", "https://ejemplo.test/activate?token=abc");
        ctx.setVariable("ttlMinutes", ttlMinutes);
        EmailBranding b = EmailBranding.DEFAULT;
        ctx.setVariable("orgName", b.orgName());
        ctx.setVariable("logoFile", b.logoFile());
        ctx.setVariable("supportEmail", b.supportEmail());
        ctx.setVariable("bannerBg", b.bannerBg());
        ctx.setVariable("bannerFg", b.bannerFg());
        ctx.setVariable("accentColor", b.accentColor());
        return engine.process("email/account-activation", ctx);
    }

    @Test
    void laInvitacionDeUnaSemanaSeAnunciaEnDias() {
        // Jackson deserializa el payload del evento con enteros chicos
        // como Integer; sso-admin lo publica como long.
        assertThat(render(10080)).contains("7 días").doesNotContain("10080 minutos");
        assertThat(render(10080L)).contains("7 días");
    }

    @Test
    void unDiaVaEnSingular() {
        assertThat(render(1440)).contains("1 día").doesNotContain("1 días");
    }

    @Test
    void unPlazoQueNoEsDiasExactosSigueEnMinutos() {
        assertThat(render(90)).contains("90 minutos");
    }
}
