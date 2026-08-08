package com.co.eurekatic.query.routing;

import org.junit.jupiter.api.Test;

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
}
