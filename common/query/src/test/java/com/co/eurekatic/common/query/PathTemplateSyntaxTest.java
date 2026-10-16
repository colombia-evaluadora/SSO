package com.co.eurekatic.common.query;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class PathTemplateSyntaxTest {

    @Test
    void acceptsUppercaseVariables() {
        PathTemplateSyntax.validate("/establecimiento/:NOMBRE");
        PathTemplateSyntax.validate("/municipio/:MUNICIPIO/establecimientos");
        PathTemplateSyntax.validate("/x/:A_1");
        PathTemplateSyntax.validate("/sin/variables");
    }

    @Test
    void rejectsLegacyBraceSyntax() {
        assertThatThrownBy(() -> PathTemplateSyntax.validate("/establecimiento/{nombre}"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("{nombre}")
                .hasMessageContaining(":NOMBRE");
    }

    @Test
    void rejectsLowercaseVariableNames() {
        assertThatThrownBy(() -> PathTemplateSyntax.validate("/establecimiento/:nombre"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("MAYÚSCULA");
    }

    @Test
    void rejectsWildcards() {
        // '**' es el caso obvio, pero '*' y '?' también son comodines
        // para PathPattern y convertirían una ruta literal en una
        // comodín sin que el admin lo pretendiera.
        assertThatThrownBy(() -> PathTemplateSyntax.validate("/establecimiento/**"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("comodines");
        assertThatThrownBy(() -> PathTemplateSyntax.validate("/reporte/*"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("comodines");
        assertThatThrownBy(() -> PathTemplateSyntax.validate("/a/?x"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("comodines");
    }

    @Test
    void rejectsTemplateNotStartingWithSlash() {
        // Se afirma sobre la frase concreta y no sobre "/": la entrada
        // ya contiene una barra y el mensaje reproduce la plantilla,
        // así que hasMessageContaining("/") pasaría aunque saltara
        // una regla distinta.
        assertThatThrownBy(() -> PathTemplateSyntax.validate("establecimiento/:NOMBRE"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("debe empezar por '/'");
    }

    @Test
    void rejectsDuplicateVariableNames() {
        // Igual que arriba: "X" aparece también en el mensaje de
        // nombre inválido, así que se afirma sobre la frase propia
        // de este error.
        assertThatThrownBy(() -> PathTemplateSyntax.validate("/a/:X/b/:X"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("más de una vez");
    }

    @Test
    void rejectsNullOrBlankTemplate() {
        assertThatThrownBy(() -> PathTemplateSyntax.validate(null))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("no puede estar vacía");
        assertThatThrownBy(() -> PathTemplateSyntax.validate("   "))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("no puede estar vacía");
        assertThat(PathTemplateSyntax.toBracePattern(null)).isNull();
    }

    /**
     * El fallo que motivó ensanchar el patrón: con un detector
     * ASCII-only, ':AÑO' se leía como la variable 'A', pasaba la
     * validación, y acababa traducido a '{A}ÑO'. En un catálogo en
     * español eso no es un caso de borde.
     */
    @Test
    void rejectsNonAsciiAndMalformedVariableNames() {
        for (String bad : new String[] {
                "/establecimiento/:AÑO",
                "/establecimiento/:CÓDIGO",
                "/a/:9A",
                "/a/:_FOO",
                "/a/:x",
                "/a/:",
                "/:A:B" }) {
            assertThatThrownBy(() -> PathTemplateSyntax.validate(bad))
                    .describedAs("debe rechazar %s", bad)
                    .isInstanceOf(IllegalArgumentException.class);
        }
    }

    @Test
    void translatesToBracePatternForPathPattern() {
        assertThat(PathTemplateSyntax.toBracePattern("/establecimiento/:NOMBRE"))
                .isEqualTo("/establecimiento/{NOMBRE}");
        assertThat(PathTemplateSyntax.toBracePattern("/municipio/:M/est/:ID"))
                .isEqualTo("/municipio/{M}/est/{ID}");
        assertThat(PathTemplateSyntax.toBracePattern("/sin/variables"))
                .isEqualTo("/sin/variables");
    }
}
