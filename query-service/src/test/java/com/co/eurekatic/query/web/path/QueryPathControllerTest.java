package com.co.eurekatic.query.web.path;

import org.junit.jupiter.api.Nested;
import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Unit tests for {@link QueryPathController#flattenToPaths}.
 *
 * <p>The method is package-private precisely so this test can
 * drive it without a Spring context, a database, or a JWT —
 * the body→bind-name translation is pure data, and pinning
 * it here is the cheapest way to catch a regression in the
 * wire contract. The end-to-end dispatch path is exercised
 * separately by {@code QueryPathDispatcherIntegrationTest}.
 *
 * <p>Contract pinned by these tests:
 * <ul>
 *   <li>Top-level scalar fields bind as
 *       {@code body.<field>}.</li>
 *   <li>Nested objects recurse — every leaf becomes a
 *       dotted bind path, no depth limit.</li>
 *   <li>Arrays (and other non-Map values) are kept as-is
 *       and bound as a single parameter.</li>
 *   <li>Empty body returns an empty map (no parameter
 *       pollution from a missing body).</li>
 *   <li>Insertion order is preserved (LinkedHashMap out) —
 *       callers can rely on a deterministic iteration order
 *       when building a WHERE clause by hand.</li>
 * </ul>
 */
class QueryPathControllerTest {

    @Nested
    class FlattenToPaths {

        @Test
        void topLevelScalarFieldsArePrefixedWithBody() {
            Map<String, Object> body = new LinkedHashMap<>();
            body.put("page", 1);
            body.put("size", 20);
            body.put("nombre", "jorge");

            Map<String, Object> out = QueryPathController.flattenToPaths(body, "body");

            assertThat(out).containsOnly(
                    Map.entry("body.page", 1),
                    Map.entry("body.size", 20),
                    Map.entry("body.nombre", "jorge")
            );
        }

        @Test
        void nestedObjectsRecurseWithDottedPath() {
            // The realistic example from the JavaDoc:
            // {"filtros":{"regional":"x"}} → body.filtros.regional = "x"
            Map<String, Object> body = Map.of(
                    "filtros", Map.of("regional", "x")
            );

            Map<String, Object> out = QueryPathController.flattenToPaths(body, "body");

            assertThat(out).containsExactly(Map.entry("body.filtros.regional", "x"));
        }

        @Test
        void arbitrarilyDeepNestingAllFlattened() {
            // Three levels deep — the regression case for the old
            // "drop with WARN" behavior, which silently dropped
            // anything beyond the first level.
            Map<String, Object> body = Map.of(
                    "filtros", Map.of(
                            "metadata", Map.of(
                                    "audit", Map.of("created_by", "sso")
                            )
                    )
            );

            Map<String, Object> out = QueryPathController.flattenToPaths(body, "body");

            assertThat(out).containsExactly(
                    Map.entry("body.filtros.metadata.audit.created_by", "sso")
            );
        }

        @Test
        void arrayValuesAreKeptAsIs() {
            // JDBC binds lists to IN(?) and array-:placeholders via
            // the Postgres driver's multi-row support; we don't try
            // to explode the array into individual parameters.
            Map<String, Object> body = new LinkedHashMap<>();
            body.put("tags", List.of("a", "b", "c"));

            Map<String, Object> out = QueryPathController.flattenToPaths(body, "body");

            assertThat(out).containsExactly(Map.entry("body.tags", List.of("a", "b", "c")));
        }

        @Test
        void mixedScalarsAndNestedObjects() {
            Map<String, Object> filtros = new LinkedHashMap<>();
            filtros.put("regional", "norte");
            filtros.put("estado", "activo");

            Map<String, Object> body = new LinkedHashMap<>();
            body.put("filtros", filtros);
            body.put("page", 1);
            body.put("size", 20);

            Map<String, Object> out = QueryPathController.flattenToPaths(body, "body");

            assertThat(out).containsExactly(
                    Map.entry("body.filtros.regional", "norte"),
                    Map.entry("body.filtros.estado", "activo"),
                    Map.entry("body.page", 1),
                    Map.entry("body.size", 20)
            );
        }

        @Test
        void emptyBodyYieldsEmptyMap() {
            assertThat(QueryPathController.flattenToPaths(Map.of(), "body"))
                    .isEmpty();
        }

        @Test
        void insertionOrderIsPreserved() {
            // LinkedHashMap in → LinkedHashMap out. This matters
            // because QueryService iterates the params map to bind
            // OUT params onto a CallableStatement in declaration
            // order, and procedure authors expect that order to
            // match the order they wrote the params in the JSON.
            Map<String, Object> body = new LinkedHashMap<>();
            body.put("z_first", 1);
            body.put("a_second", 2);
            body.put("m_third", 3);

            Map<String, Object> out = QueryPathController.flattenToPaths(body, "body");

            assertThat(out.keySet())
                    .containsExactly("body.z_first", "body.a_second", "body.m_third");
        }

        @Test
        void prefixCanBeCustomisedForUnitTesting() {
            // The prefix parameter is exposed only because the
            // recursion needs to thread the current path; verifying
            // with a different prefix ensures tests aren't
            // accidentally coupled to the public "body" choice.
            Map<String, Object> body = Map.of("a", "1");

            Map<String, Object> out = QueryPathController.flattenToPaths(body, "req");

            assertThat(out).containsExactly(Map.entry("req.a", "1"));
        }

        @Test
        void nullValuesArePreservedAsBindParameters() {
            // A field with an explicit null should still bind —
            // MapSqlParameterSource treats null as a real
            // parameter (useful for procedures that interpret
            // null as "argument not provided").
            //
            // We can't use Map.entry(k, v) to express the
            // expected value: the JDK Map.entry() factory
            // throws NullPointerException when EITHER the key
            // or the value is null. Build the expected map
            // directly with a LinkedHashMap entry and assert
            // size + key/value pairs separately.
            Map<String, Object> body = new LinkedHashMap<>();
            body.put("optional", null);

            Map<String, Object> out = QueryPathController.flattenToPaths(body, "body");

            assertThat(out).hasSize(1);
            assertThat(out).containsKey("body.optional");
            assertThat(out.get("body.optional")).isNull();
        }
    }
}
