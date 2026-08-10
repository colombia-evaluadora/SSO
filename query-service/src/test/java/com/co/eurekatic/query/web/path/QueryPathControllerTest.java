package com.co.eurekatic.query.web.path;

import org.junit.jupiter.api.Nested;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * Cómo se arma el mapa de binds a partir de la petición.
 *
 * <p>Estos casos probaban antes {@code flattenToPaths}, un método
 * privado del controller. El aplanado vive ahora en
 * {@code ParamNamespace} (módulo common, con sus propios tests),
 * así que aquí se ejercita a través de {@code buildParams}, que es
 * la superficie que el controller usa de verdad: la mezcla de los
 * tres orígenes que controla el llamante.
 */
class QueryPathControllerTest {

    @Nested
    class BodyFlattening {

        @Test
        void topLevelScalarFieldsArePrefixedWithBody() {
            Map<String, Object> body = new LinkedHashMap<>();
            body.put("page", 1);
            body.put("size", 20);
            body.put("nombre", "jorge");

            Map<String, Object> out =
                    QueryPathController.buildParams(Map.of(), Map.of(), body);

            assertThat(out).containsOnly(
                    Map.entry("BODY.PAGE", 1),
                    Map.entry("BODY.SIZE", 20),
                    Map.entry("BODY.NOMBRE", "jorge"));
        }

        @Test
        void nestedObjectsRecurseWithDottedPath() {
            Map<String, Object> body = Map.of("filtros", Map.of("regional", "x"));

            Map<String, Object> out =
                    QueryPathController.buildParams(Map.of(), Map.of(), body);

            assertThat(out).containsExactly(Map.entry("BODY.FILTROS.REGIONAL", "x"));
        }

        @Test
        void arbitrarilyDeepNestingAllFlattened() {
            Map<String, Object> body = Map.of(
                    "a", Map.of("b", Map.of("c", Map.of("d", "hondo"))));

            Map<String, Object> out =
                    QueryPathController.buildParams(Map.of(), Map.of(), body);

            assertThat(out).containsExactly(Map.entry("BODY.A.B.C.D", "hondo"));
        }

        /**
         * Los arrays se bindean enteros. Trocearlos por índice
         * produciría nombres que nadie puede escribir en una SQL.
         */
        @Test
        void arrayValuesAreKeptAsIs() {
            Map<String, Object> body = Map.of("tags", List.of("a", "b"));

            Map<String, Object> out =
                    QueryPathController.buildParams(Map.of(), Map.of(), body);

            assertThat(out).containsExactly(Map.entry("BODY.TAGS", List.of("a", "b")));
        }

        @Test
        void mixedScalarsAndNestedObjects() {
            Map<String, Object> body = new LinkedHashMap<>();
            body.put("page", 1);
            body.put("filtros", Map.of("zona", 214));

            Map<String, Object> out =
                    QueryPathController.buildParams(Map.of(), Map.of(), body);

            assertThat(out)
                    .containsEntry("BODY.PAGE", 1)
                    .containsEntry("BODY.FILTROS.ZONA", 214);
        }

        @Test
        void emptyBodyYieldsNoBodyParams() {
            Map<String, Object> out =
                    QueryPathController.buildParams(Map.of(), Map.of(), Map.of());

            assertThat(out).isEmpty();
        }

        @Test
        void insertionOrderIsPreserved() {
            Map<String, Object> body = new LinkedHashMap<>();
            body.put("z", 1);
            body.put("a", 2);
            body.put("m", 3);

            Map<String, Object> out =
                    QueryPathController.buildParams(Map.of(), Map.of(), body);

            assertThat(new ArrayList<>(out.keySet()))
                    .containsExactly("BODY.Z", "BODY.A", "BODY.M");
        }

        /**
         * Un null del JSON se conserva como bind: la SQL puede
         * querer distinguir "no me mandaron nada" de "me mandaron
         * vacío", y eso lo decide el autor, no el dispatcher.
         */
        @Test
        void nullValuesArePreservedAsBindParameters() {
            Map<String, Object> body = new LinkedHashMap<>();
            body.put("opcional", null);

            Map<String, Object> out =
                    QueryPathController.buildParams(Map.of(), Map.of(), body);

            assertThat(out).containsKey("BODY.OPCIONAL");
            assertThat(out.get("BODY.OPCIONAL")).isNull();
        }
    }

    @Nested
    class NamespaceIsolation {

        @Test
        void mergesTheThreeCallerSourcesUnderTheirNamespaces() {
            Map<String, String> queryParams = new LinkedHashMap<>();
            queryParams.put("size", "20");

            Map<String, Object> params = QueryPathController.buildParams(
                    Map.of("MUNICIPIO", "404"),
                    queryParams,
                    Map.of("filtros", Map.of("zona", 214)));

            assertThat(params)
                    .containsEntry("PARAM.MUNICIPIO", "404")
                    .containsEntry("QUERY.SIZE", "20")
                    .containsEntry("BODY.FILTROS.ZONA", 214);
        }

        /**
         * Antes los query params PISABAN a las variables de ruta
         * ({@code putAll(pathVars)} y luego
         * {@code putAll(queryParams)}), así que una ruta declarada
         * podía secuestrarse desde el query string. Con namespaces
         * la colisión es imposible por construcción.
         */
        @Test
        void queryParamsCannotOverridePathVariables() {
            Map<String, Object> params = QueryPathController.buildParams(
                    Map.of("NOMBRE", "delPath"),
                    Map.of("NOMBRE", "delQueryString"),
                    null);

            assertThat(params)
                    .containsEntry("PARAM.NOMBRE", "delPath")
                    .containsEntry("QUERY.NOMBRE", "delQueryString");
        }

        @Test
        void handlesNullBody() {
            Map<String, Object> params = QueryPathController.buildParams(
                    Map.of("ID", "1"), Map.of(), null);

            assertThat(params).containsExactly(Map.entry("PARAM.ID", "1"));
        }

        @Test
        void rejectsQueryParamsThatCollideByCase() {
            Map<String, String> queryParams = new LinkedHashMap<>();
            queryParams.put("estado", "a");
            queryParams.put("ESTADO", "b");

            assertThatThrownBy(() ->
                    QueryPathController.buildParams(Map.of(), queryParams, null))
                    .isInstanceOf(IllegalArgumentException.class)
                    .hasMessageContaining("ESTADO");
        }

        /**
         * Un guion rompería el parseo del bind en el SQL
         * ({@code :QUERY.PAGE} seguido de {@code -SIZE} suelto), así
         * que se rechaza al entrar en vez de producir SQL corrupto.
         */
        @Test
        void rejectsQueryParamNamesThatCannotBeWrittenInSql() {
            assertThatThrownBy(() -> QueryPathController.buildParams(
                    Map.of(), Map.of("page-size", "20"), null))
                    .isInstanceOf(IllegalArgumentException.class);
        }
    }
}
