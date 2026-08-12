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

    /**
     * Un guion en la clave no es una cuestión de estilo: Spring
     * corta el nombre de un bind en el guion, así que
     * {@code ?page-size=1} produciría {@code :QUERY.PAGE} seguido
     * de {@code -SIZE} suelto en mitad del SQL — ni error de
     * parseo ni resultado correcto.
     */
    @Test
    void rejectsKeysThatWouldNotSurviveSqlParameterParsing() {
        for (String bad : new String[] { "page-size", "a b", "x.y", "2X", "" }) {
            Map<String, Object> out = new LinkedHashMap<>();
            assertThatThrownBy(() ->
                    ParamNamespace.putAll(out, ParamNamespace.QUERY, Map.of(bad, "v")))
                    .describedAs("debe rechazar la clave '%s'", bad)
                    .isInstanceOf(IllegalArgumentException.class);
        }
    }

    /**
     * Los nombres se translitran, no se aceptan con acento: la
     * clave que envía el cliente y el bind que el autor escribe en
     * el SQL tienen que poder deducirse el uno del otro.
     */
    @Test
    void rejectsAccentedKeysAndSuggestsTransliteration() {
        Map<String, Object> out = new LinkedHashMap<>();

        assertThatThrownBy(() ->
                ParamNamespace.putAll(out, ParamNamespace.QUERY, Map.of("año", "2026")))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("ANIO");

        assertThatThrownBy(() ->
                ParamNamespace.flatten(Map.of("año", 2026), ParamNamespace.BODY))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("ANIO");

        ParamNamespace.putAll(out, ParamNamespace.QUERY, Map.of("anio", "2026"));
        assertThat(out).containsEntry("QUERY.ANIO", "2026");
    }

    @Test
    void isValidNameIsTheOneRuleForEveryParameterOrigin() {
        assertThat(ParamNamespace.isValidName("NOMBRE")).isTrue();
        assertThat(ParamNamespace.isValidName("A_1")).isTrue();
        assertThat(ParamNamespace.isValidName("AÑO")).isFalse();
        assertThat(ParamNamespace.isValidName("nombre")).isFalse();
        assertThat(ParamNamespace.isValidName("_X")).isFalse();
        assertThat(ParamNamespace.isValidName(null)).isFalse();
    }

    @Test
    void exposesTheFourNamespaces() {
        assertThat(ParamNamespace.PARAM).isEqualTo("PARAM");
        assertThat(ParamNamespace.QUERY).isEqualTo("QUERY");
        assertThat(ParamNamespace.BODY).isEqualTo("BODY");
        assertThat(ParamNamespace.BODY_RAW).isEqualTo("BODY_RAW");
        assertThat(ParamNamespace.CONTEXT).isEqualTo("CONTEXT");
    }

    /* ====================== V49-bis — BODY_RAW namespace ====================== */

    @Test
    void putRawExposesTopLevelMapIntact() {
        // Body: {filtro: {zona: 1, nivel: 'A'}}
        Map<String, Object> filtro = new LinkedHashMap<>();
        filtro.put("zona", 1);
        filtro.put("nivel", "A");

        Map<String, Object> body = new LinkedHashMap<>();
        body.put("filtro", filtro);

        Map<String, Object> out = new LinkedHashMap<>();
        ParamNamespace.putRaw(out, body);

        // El valor completo del sub-objeto, sin aplanar.
        assertThat(out).containsEntry("BODY_RAW.FILTRO", filtro);
    }

    @Test
    void putRawUppercasesTopLevelKeys() {
        Map<String, Object> filtro = Map.of("zona", 1);

        Map<String, Object> body = new LinkedHashMap<>();
        body.put("filtro", filtro);

        Map<String, Object> out = new LinkedHashMap<>();
        ParamNamespace.putRaw(out, body);

        assertThat(out).containsKey("BODY_RAW.FILTRO");
        assertThat(out.get("BODY_RAW.FILTRO")).isSameAs(filtro);
    }

    @Test
    void putRawKeepsArraysIntactAsValues() {
        // Body: {tags: ['a','b','c']}
        Map<String, Object> body = Map.of("tags", java.util.List.of("a", "b", "c"));

        Map<String, Object> out = new LinkedHashMap<>();
        ParamNamespace.putRaw(out, body);

        assertThat(out).containsEntry("BODY_RAW.TAGS", java.util.List.of("a", "b", "c"));
    }

    @Test
    void putRawRejectsKeysThatCollideByCase() {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("filtro", Map.of("a", 1));
        body.put("FILTRO", Map.of("b", 2));

        Map<String, Object> out = new LinkedHashMap<>();
        assertThatThrownBy(() -> ParamNamespace.putRaw(out, body))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("FILTRO");
    }

    @Test
    void putRawToleratesNullAndEmptySource() {
        Map<String, Object> out = new LinkedHashMap<>();
        ParamNamespace.putRaw(out, null);
        ParamNamespace.putRaw(out, Map.of());
        assertThat(out).isEmpty();
    }

    @Test
    void putRawAndFlattenCoexistOnSameBody() {
        // El body produce entradas tanto en BODY.* (escalares aplanados) como
        // en BODY_RAW.* (sub-objetos completos). No se pisan porque los
        // namespaces son disjuntos.
        Map<String, Object> filtro = new LinkedHashMap<>();
        filtro.put("zona", 1);

        Map<String, Object> body = new LinkedHashMap<>();
        body.put("zona", 214);         // escalar top-level
        body.put("filtro", filtro);    // sub-objeto

        Map<String, Object> out = new LinkedHashMap<>();
        ParamNamespace.putAll(out, ParamNamespace.QUERY, null);
        // Llamamos ambos — debe funcionar sin colisión.
        out.putAll(ParamNamespace.flatten(body, ParamNamespace.BODY));
        ParamNamespace.putRaw(out, body);

        assertThat(out).containsEntry("BODY.ZONA", 214);
        assertThat(out).containsEntry("BODY_RAW.FILTRO", filtro);
    }
}
