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
    void rejectsWildcard() {
        assertThatThrownBy(() -> PathTemplateSyntax.validate("/establecimiento/**"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("**");
    }

    @Test
    void rejectsTemplateNotStartingWithSlash() {
        assertThatThrownBy(() -> PathTemplateSyntax.validate("establecimiento/:NOMBRE"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("/");
    }

    @Test
    void rejectsDuplicateVariableNames() {
        assertThatThrownBy(() -> PathTemplateSyntax.validate("/a/:X/b/:X"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("X");
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
