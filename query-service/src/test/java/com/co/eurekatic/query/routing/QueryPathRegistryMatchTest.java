package com.co.eurekatic.query.routing;

import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * El matching se prueba sobre el helper estático para no montar el
 * contexto de Spring ni mockear el catálogo: lo que importa aquí es
 * la gramática y, sobre todo, la decodificación.
 */
class QueryPathRegistryMatchTest {

    @Test
    void matchesAndExtractsUppercaseVariable() {
        var match = QueryPathRegistry.matchTemplate(
                "/establecimiento/:NOMBRE", "/establecimiento/PRUEBA2025");

        assertThat(match).isPresent();
        assertThat(match.get()).containsEntry("NOMBRE", "PRUEBA2025");
    }

    /**
     * El bug que originó todo esto. Con AntPathMatcher el valor
     * llegaba como "PRUDENCIA%20DAZA" hasta la SQL, y como la
     * consulta usa LIKE ese '%' actuaba además de comodín. Nunca
     * daba error: daba 200 con lista vacía.
     */
    @Test
    void decodesSpacesInTheValue() {
        var match = QueryPathRegistry.matchTemplate(
                "/establecimiento/:NOMBRE", "/establecimiento/PRUDENCIA%20DAZA");

        assertThat(match).isPresent();
        assertThat(match.get()).containsEntry("NOMBRE", "PRUDENCIA DAZA");
    }

    @Test
    void decodesAccentsInTheValue() {
        var match = QueryPathRegistry.matchTemplate(
                "/establecimiento/:NOMBRE", "/establecimiento/INSTITUCI%C3%93N");

        assertThat(match).isPresent();
        assertThat(match.get()).containsEntry("NOMBRE", "INSTITUCIÓN");
    }

    /**
     * Un %2F dentro del valor no debe partir en segmentos: si lo
     * hiciera, quien llama podría hacer casar una plantilla que no
     * le corresponde.
     */
    @Test
    void encodedSlashDoesNotInjectPathSegments() {
        var encoded = QueryPathRegistry.matchTemplate("/est/:NOMBRE", "/est/A%2FB");
        assertThat(encoded).isPresent();
        assertThat(encoded.get()).containsEntry("NOMBRE", "A/B");

        var literal = QueryPathRegistry.matchTemplate("/est/:NOMBRE", "/est/A/B");
        assertThat(literal).isEmpty();
    }

    @Test
    void matchesMultipleVariables() {
        var match = QueryPathRegistry.matchTemplate(
                "/municipio/:MUNICIPIO/est/:ID", "/municipio/404/est/528");

        assertThat(match).isPresent();
        assertThat(match.get())
                .containsEntry("MUNICIPIO", "404")
                .containsEntry("ID", "528");
    }

    @Test
    void doesNotMatchDifferentPath() {
        assertThat(QueryPathRegistry.matchTemplate(
                "/establecimiento/:NOMBRE", "/otra/cosa")).isEmpty();
    }

    /**
     * V33 — la clave del registro es (verbo, plantilla), así que la
     * misma ruta puede servir propósitos distintos según el método.
     * {@code matchTemplate} no sabe de verbos: el filtrado por
     * método ocurre en {@code match}, y aquí sólo se fija que la
     * gramática siga siendo la misma para todos.
     */
    @Test
    void routeKeyDistinguishesMethodsOnTheSameTemplate() {
        var get = new QueryPathRegistry.RouteKey("GET", "/est/:ID");
        var put = new QueryPathRegistry.RouteKey("PUT", "/est/:ID");

        assertThat(get).isNotEqualTo(put);
        assertThat(get).isEqualTo(new QueryPathRegistry.RouteKey("GET", "/est/:ID"));
    }

    @Test
    void toleratesTrailingSlash() {
        var match = QueryPathRegistry.matchTemplate(
                "/establecimiento/:NOMBRE", "/establecimiento/X/");

        assertThat(match).isPresent();
        assertThat(match.get()).containsEntry("NOMBRE", "X");
    }

    /**
     * El bug real que motivó {@code matchAgainst}: con las dos filas
     * insertadas en este orden (el {@code :ID} genérico primero,
     * como en el catálogo real — id 58 antes que id 69), un match
     * "primero que gane" resolvía SIEMPRE al {@code :ID} porque
     * {@code eliminacion-masiva} es un valor de ruta tan válido como
     * cualquier otro. {@code /grados/eliminacion-masiva} quedaba
     * inalcanzable para cualquier cliente real, no sólo el harness.
     */
    @Test
    void literalTemplateWinsOverShadowingWildcardRegardlessOfInsertionOrder() {
        Map<QueryPathRegistry.RouteKey, String> table = new LinkedHashMap<>();
        table.put(new QueryPathRegistry.RouteKey("PUT", "/grados/:ID"), "uuid-wildcard");
        table.put(new QueryPathRegistry.RouteKey("PUT", "/grados/eliminacion-masiva"), "uuid-literal");

        var match = QueryPathRegistry.matchAgainst(table, "PUT", "/grados/eliminacion-masiva");

        assertThat(match).isPresent();
        assertThat(match.get().uuid()).isEqualTo("uuid-literal");
    }

    /** Mismo caso pero con la tabla en el orden contrario, para probar
     *  que el resultado no depende del orden de inserción. */
    @Test
    void literalTemplateWinsOverShadowingWildcardEvenWhenInsertedFirst() {
        Map<QueryPathRegistry.RouteKey, String> table = new LinkedHashMap<>();
        table.put(new QueryPathRegistry.RouteKey("PUT", "/establecimientos/sedes/bulk-delete"), "uuid-literal");
        table.put(new QueryPathRegistry.RouteKey("PUT", "/establecimientos/sedes/:ID"), "uuid-wildcard");

        var match = QueryPathRegistry.matchAgainst(table, "PUT", "/establecimientos/sedes/bulk-delete");

        assertThat(match).isPresent();
        assertThat(match.get().uuid()).isEqualTo("uuid-literal");
    }

    /** El :ID sigue resolviendo normalmente para valores que no
     *  colisionan con ningún literal registrado. */
    @Test
    void wildcardStillMatchesRealIds() {
        Map<QueryPathRegistry.RouteKey, String> table = new LinkedHashMap<>();
        table.put(new QueryPathRegistry.RouteKey("PUT", "/grados/:ID"), "uuid-wildcard");
        table.put(new QueryPathRegistry.RouteKey("PUT", "/grados/eliminacion-masiva"), "uuid-literal");

        var match = QueryPathRegistry.matchAgainst(table, "PUT", "/grados/1750");

        assertThat(match).isPresent();
        assertThat(match.get().uuid()).isEqualTo("uuid-wildcard");
        assertThat(match.get().pathVars()).containsEntry("ID", "1750");
    }

    /** Ambigüedad real (misma especificidad, dos templates distintos
     *  matchean la misma ruta): no hay forma correcta de desempatar,
     *  así que se preserva el comportamiento histórico — gana el
     *  primero en orden de inserción — en vez de fallar o elegir al
     *  azar. */
    @Test
    void tiesFallBackToInsertionOrder() {
        // Ambas plantillas matchean "/a/b/c" con exactamente 1
        // variable extraída — empate genuino de especificidad.
        Map<QueryPathRegistry.RouteKey, String> table = new LinkedHashMap<>();
        table.put(new QueryPathRegistry.RouteKey("GET", "/a/:X/c"), "uuid-first");
        table.put(new QueryPathRegistry.RouteKey("GET", "/a/b/:Y"), "uuid-second");

        var match = QueryPathRegistry.matchAgainst(table, "GET", "/a/b/c");

        assertThat(match).isPresent();
        assertThat(match.get().uuid()).isEqualTo("uuid-first");
    }

    @Test
    void noMatchReturnsEmpty() {
        Map<QueryPathRegistry.RouteKey, String> table = new LinkedHashMap<>();
        table.put(new QueryPathRegistry.RouteKey("GET", "/grados/:ID"), "uuid-wildcard");

        assertThat(QueryPathRegistry.matchAgainst(table, "PUT", "/grados/1750")).isEmpty();
        assertThat(QueryPathRegistry.matchAgainst(table, "GET", "/otra/cosa")).isEmpty();
    }
}
