package com.co.eurekatic.common.query;

import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ParamNamespaceTest {

    @Test
    void prefixesAndUppercasesCallerKeys() {
        Map<String, String> in = new LinkedHashMap<>();
        in.put("estado", "activo");
        in.put("SIZE", "20");

        Map<String, Object> out = new LinkedHashMap<>();
        ParamNamespace.putAll(out, ParamNamespace.QUERY, in);

        assertThat(out).containsEntry("QUERY.ESTADO", "activo");
        assertThat(out).containsEntry("QUERY.SIZE", "20");
    }

    @Test
    void rejectsKeysThatDifferOnlyByCase() {
        Map<String, String> in = new LinkedHashMap<>();
        in.put("estado", "a");
        in.put("ESTADO", "b");

        Map<String, Object> out = new LinkedHashMap<>();
        assertThatThrownBy(() -> ParamNamespace.putAll(out, ParamNamespace.QUERY, in))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("ESTADO");
    }

    @Test
    void flattensNestedBodyWithDottedUppercasePaths() {
        Map<String, Object> body = Map.of(
                "filtros", Map.of("zona", 214));

        Map<String, Object> out = ParamNamespace.flatten(body, ParamNamespace.BODY);

        assertThat(out).containsEntry("BODY.FILTROS.ZONA", 214);
    }

    @Test
    void keepsArraysIntactWhenFlattening() {
        Map<String, Object> body = Map.of("tags", java.util.List.of("a", "b"));

        Map<String, Object> out = ParamNamespace.flatten(body, ParamNamespace.BODY);

        assertThat(out).containsEntry("BODY.TAGS", java.util.List.of("a", "b"));
    }

    @Test
    void rejectsNestedKeysThatCollideByCase() {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("zona", 1);
        body.put("ZONA", 2);

        assertThatThrownBy(() -> ParamNamespace.flatten(body, ParamNamespace.BODY))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("ZONA");
    }

    @Test
    void collisionCheckIsPerLevelNotGlobal() {
        // Dos ramas distintas pueden tener la misma clave sin colisionar:
        // BODY.A.X y BODY.B.X son nombres distintos.
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("a", Map.of("x", 1));
        body.put("b", Map.of("x", 2));

        Map<String, Object> out = ParamNamespace.flatten(body, ParamNamespace.BODY);

        assertThat(out)
                .containsEntry("BODY.A.X", 1)
                .containsEntry("BODY.B.X", 2);
    }

    @Test
    void toleratesNullAndEmptySources() {
        Map<String, Object> out = new LinkedHashMap<>();
        ParamNamespace.putAll(out, ParamNamespace.QUERY, null);
        ParamNamespace.putAll(out, ParamNamespace.QUERY, Map.of());

        assertThat(out).isEmpty();
        assertThat(ParamNamespace.flatten(Map.of(), ParamNamespace.BODY)).isEmpty();
    }

    @Test
    void exposesTheFourNamespaces() {
        assertThat(ParamNamespace.PARAM).isEqualTo("PARAM");
        assertThat(ParamNamespace.QUERY).isEqualTo("QUERY");
        assertThat(ParamNamespace.BODY).isEqualTo("BODY");
        assertThat(ParamNamespace.CONTEXT).isEqualTo("CONTEXT");
    }
}
