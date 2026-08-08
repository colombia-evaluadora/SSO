package com.co.eurekatic.query.web.path;

import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class QueryPathControllerParamsTest {

    @Test
    void mergesTheThreeCallerSourcesUnderTheirNamespaces() {
        Map<String, String> pathVars = Map.of("MUNICIPIO", "404");
        Map<String, String> queryParams = new LinkedHashMap<>();
        queryParams.put("size", "20");
        Map<String, Object> body = Map.of("filtros", Map.of("zona", 214));

        Map<String, Object> params =
                QueryPathController.buildParams(pathVars, queryParams, body);

        assertThat(params)
                .containsEntry("PARAM.MUNICIPIO", "404")
                .containsEntry("QUERY.SIZE", "20")
                .containsEntry("BODY.FILTROS.ZONA", 214);
    }

    /**
     * Antes los query params PISABAN a las variables de ruta
     * ({@code putAll(pathVars)} y luego {@code putAll(queryParams)}),
     * así que una ruta declarada podía secuestrarse desde el query
     * string. Con namespaces la colisión es imposible por
     * construcción, no por convenio.
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
     * Un guion en la clave rompería el parseo del bind en el SQL
     * ({@code :QUERY.PAGE} seguido de {@code -SIZE} suelto), así que
     * se rechaza al entrar en vez de producir SQL corrupto.
     */
    @Test
    void rejectsQueryParamNamesThatCannotBeWrittenInSql() {
        assertThatThrownBy(() -> QueryPathController.buildParams(
                Map.of(), Map.of("page-size", "20"), null))
                .isInstanceOf(IllegalArgumentException.class);
    }
}
