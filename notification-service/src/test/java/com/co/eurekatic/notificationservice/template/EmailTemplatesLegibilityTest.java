package com.co.eurekatic.notificationservice.template;

import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.junit.jupiter.api.Test;
import org.thymeleaf.context.Context;
import org.thymeleaf.spring6.SpringTemplateEngine;
import org.thymeleaf.templatemode.TemplateMode;
import org.thymeleaf.templateresolver.ClassLoaderTemplateResolver;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Legibilidad de los correos en modo oscuro y en movil. Nace de un reporte
 * en Gmail Android oscuro: el aviso de vigencia del enlace era gris claro
 * (#6b7688/#8a94a6) a 13.5px sobre casi negro, al lado de un reloj que Gmail
 * no carga hasta que el usuario acepta las imagenes, y el saludo salia
 * "Hola, Administrador MALDONADO ." por un apellido vacio.
 *
 * <p>Ademas deja cada plantilla renderizada en
 * {@code target/email-preview/} para revisarla a ojo en un navegador
 * (con el tema del sistema en claro y en oscuro).
 */
class EmailTemplatesLegibilityTest {

    private static String render(String plantilla, Map<String, Object> extra) {
        ClassLoaderTemplateResolver resolver = new ClassLoaderTemplateResolver();
        resolver.setPrefix("templates/");
        resolver.setSuffix(".html");
        resolver.setTemplateMode(TemplateMode.HTML);
        resolver.setCharacterEncoding("UTF-8");
        SpringTemplateEngine engine = new SpringTemplateEngine();
        engine.setTemplateResolver(resolver);

        Context ctx = new Context();
        ctx.setVariable("displayName", "Administrador MALDONADO ");
        ctx.setVariable("email", "ana@example.com");
        ctx.setVariable("activationLink", "https://ejemplo.test/activate?token=abc");
        ctx.setVariable("resetLink", "https://ejemplo.test/restore-password?token=abc");
        ctx.setVariable("roleName", "CEVAL-DOCENTE");
        ctx.setVariable("reason", "Retiro de la institucion");
        ctx.setVariables(extra);
        EmailBranding b = EmailBranding.DEFAULT;
        ctx.setVariable("orgName", b.orgName());
        ctx.setVariable("logoFile", b.logoFile());
        ctx.setVariable("supportEmail", b.supportEmail());
        ctx.setVariable("bannerBg", b.bannerBg());
        ctx.setVariable("bannerFg", b.bannerFg());
        ctx.setVariable("accentColor", b.accentColor());
        String html = engine.process("email/" + plantilla, ctx);
        try {
            Path out = Path.of("target", "email-preview", plantilla + ".html");
            Files.createDirectories(out.getParent());
            Files.writeString(out, html, StandardCharsets.UTF_8);
        } catch (IOException ignored) {
            // La vista previa es un extra; el test no depende de ella.
        }
        return html;
    }

    @ParameterizedTest
    @ValueSource(strings = {
            "account-activated", "account-activation", "account-deactivated",
            "account-reactivated", "password-changed", "password-reset",
            "role-assigned", "role-revoked"})
    void todasDeclaranModoOscuroYNoUsanGrisesIlegibles(String plantilla) {
        String html = render(plantilla, Map.of("ttlMinutes", 2880));

        assertThat(html)
                .contains("<meta name=\"color-scheme\" content=\"light dark\"/>")
                .contains("<meta name=\"supported-color-schemes\" content=\"light dark\"/>")
                .contains("@media (prefers-color-scheme: dark)")
                .contains("[data-ogsc]");
        // Los grises que en Gmail oscuro quedaban gris sobre negro.
        assertThat(html).doesNotContain("#8a94a6", "#97a0b2", "#6b7688", "#aab2c2");
        // Nada por debajo de 14px en el cuerpo.
        assertThat(html).doesNotContain("font-size:12.5px", "font-size:13px", "font-size:13.5px");
        // El saludo sin el espacio colgado antes del punto.
        assertThat(html).contains("Administrador MALDONADO.").doesNotContain("MALDONADO .");
        // El alt del logo en una sola linea si la imagen no carga.
        assertThat(html).contains("alt=\"Colombia Evaluadora\"").contains("white-space:nowrap");
    }

    @Test
    void laRecuperacionAnunciaElPlazoRealEnDias() {
        // TokenService.RESTORE_TTL_MINUTES en sso-admin = 2 dias. Antes la
        // plantilla imprimia "${ttlMinutes} minutos" -> "2880 minutos".
        String html = render("password-reset", Map.of("ttlMinutes", 2880L));
        assertThat(html).contains("2 días").doesNotContain("2880 minutos");
        assertThat(html).contains("class=\"dm-warn\"");
    }

    @Test
    void laActivacionAnunciaSieteDiasEnLaCajaDeAviso() {
        String html = render("account-activation", Map.of("ttlMinutes", 10080L));
        assertThat(html).contains("7 días").contains("class=\"dm-warn\"");
        // El reloj ya no acompana al aviso: no debe depender de una imagen.
        assertThat(html.indexOf("reloj.png")).isEqualTo(-1);
    }

}
