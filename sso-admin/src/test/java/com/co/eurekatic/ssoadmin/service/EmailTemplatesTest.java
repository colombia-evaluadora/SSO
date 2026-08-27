package com.co.eurekatic.ssoadmin.service;

import freemarker.template.Configuration;
import freemarker.template.Template;
import freemarker.template.TemplateNotFoundException;
import org.junit.jupiter.api.Test;
import org.springframework.ui.freemarker.FreeMarkerTemplateUtils;

import java.io.File;
import java.util.HashMap;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * Renderiza de verdad las plantillas de correo con datos de ejemplo.
 *
 * <p>Existe porque {@code EmailService#send} captura toda excepción a
 * propósito: un fallo al enviar no debe tumbar el alta de un usuario,
 * que ya está creado en la base. El efecto secundario es que un error
 * de sintaxis en una plantilla —una variable mal escrita, una llave
 * sin cerrar— <em>no se nota</em>: no hay excepción que suba, el
 * usuario simplemente nunca recibe el correo y lo único que queda es
 * una línea de log en un servidor.
 *
 * <p>Este test convierte ese fallo silencioso en un fallo de build.
 */
class EmailTemplatesTest {

    /** Las mismas variables que pone {@code EmailService#baseVars}. */
    private static Map<String, Object> variables() {
        Map<String, Object> vars = new HashMap<>();
        vars.put("userName", "ana@example.com");
        vars.put("email", "ana@example.com");
        vars.put("name", "Ana Pérez");
        vars.put("logo", "https://ejemplo.test/logo.png");
        vars.put("company", "Colombia Evaluadora");
        vars.put("appName", "SSO Modernizado");
        vars.put("token", "abc123def456");
        vars.put("domain", "https://ejemplo.test/restablecer");
        return vars;
    }

    private static Configuration freemarker() throws Exception {
        Configuration cfg = new Configuration(Configuration.VERSION_2_3_32);
        cfg.setDirectoryForTemplateLoading(
                new File("src/main/resources/templates"));
        cfg.setDefaultEncoding("UTF-8");
        return cfg;
    }

    private static String render(String plantilla) throws Exception {
        Template t = freemarker().getTemplate(plantilla);
        return FreeMarkerTemplateUtils.processTemplateIntoString(t, variables());
    }

    @Test
    void laPlantillaDeRecuperacionRenderizaYSustituyeTodo() throws Exception {
        String html = render("restore-password-account.html");

        // Ninguna variable se queda sin resolver. Un ${...} superviviente
        // significa que el nombre no coincide con lo que pone baseVars,
        // y el usuario recibiría el correo con el marcador a la vista.
        assertThat(html).doesNotContain("${");

        // El enlace es lo único imprescindible del correo: sin él, el
        // usuario no puede hacer nada.
        assertThat(html).contains("https://ejemplo.test/restablecer?token=abc123def456");

        assertThat(html).contains("Ana Pérez");
        assertThat(html).contains("Colombia Evaluadora");
        assertThat(html).contains("https://ejemplo.test/logo.png");

        // El plazo que anuncia el texto tiene que ser el real, no uno
        // heredado del diseño. Si alguien cambia RESTORE_TTL_MINUTES,
        // este assert obliga a mirar también la plantilla.
        assertThat(TokenService.RESTORE_TTL_MINUTES).isEqualTo(30);
        assertThat(html).contains("30 minutos");

        // Los acentos sobreviven al renderizado: el correo se envía
        // como UTF-8 y el fichero está en UTF-8, pero basta con que
        // alguien guarde la plantilla en otra codificación para que
        // aquí aparezca "contraseÃ±a".
        assertThat(html).contains("contraseña");
        assertThat(html).doesNotContain("Ã");
    }

    @Test
    void laPlantillaDeActivacionSigueRenderizando() throws Exception {
        // No se toca en este cambio, pero comparte el mismo mecanismo
        // y el mismo fallo silencioso.
        String html = render("activation-account.html");

        assertThat(html).doesNotContain("${");
        assertThat(html).contains("abc123def456");
    }

    /**
     * Comprobación de que el test SIRVE: si la plantilla no existe o
     * no compila, esto falla. Sin este caso, un test que sólo hace
     * asserts sobre una cadena vacía pasaría igual.
     */
    @Test
    void unaPlantillaInexistenteFalla() {
        assertThatThrownBy(() -> render("no-existe.html"))
                .isInstanceOf(TemplateNotFoundException.class);
    }
}
