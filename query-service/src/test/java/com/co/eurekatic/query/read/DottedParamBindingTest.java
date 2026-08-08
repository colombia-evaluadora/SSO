package com.co.eurekatic.query.read;

import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterUtils;
import org.springframework.jdbc.core.namedparam.ParsedSql;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * El esquema de namespaces entero depende de que Spring parsee
 * {@code :PARAM.NOMBRE} como UN nombre de parámetro y no lo corte
 * en el punto. Lo es — el punto no está en la lista de separadores
 * de {@code NamedParameterUtils} — pero es una garantía prestada de
 * una librería de terceros, y hasta ahora nada en esta suite la
 * comprobaba: el único test que rozaba el tema admitía en su propio
 * comentario que "our query doesn't use that placeholder".
 *
 * <p>Es un test de caracterización: documenta comportamiento que ya
 * existe. Si alguna vez falla tras subir de versión de Spring, el
 * diseño de namespaces deja de ser viable tal cual y hay que
 * replantearlo — no "arreglar" este test.
 */
class DottedParamBindingTest {

    @Test
    void dottedNamesParseAsASingleParameter() {
        ParsedSql parsed = NamedParameterUtils.parseSqlStatement(
                "SELECT * FROM t WHERE nombre = :PARAM.NOMBRE");

        assertThat(parsed.getParameterNames()).containsExactly("PARAM.NOMBRE");
    }

    @Test
    void allFourNamespacesParseInOneStatement() {
        ParsedSql parsed = NamedParameterUtils.parseSqlStatement(
                "SELECT * FROM t "
                + "WHERE municipio = :PARAM.MUNICIPIO "
                + "  AND zona = :BODY.FILTROS.ZONA "
                + "  AND owner = :CONTEXT.USER_ID "
                + "LIMIT :QUERY.SIZE");

        assertThat(parsed.getParameterNames()).containsExactly(
                "PARAM.MUNICIPIO", "BODY.FILTROS.ZONA",
                "CONTEXT.USER_ID", "QUERY.SIZE");
    }

    @Test
    void dottedNamesBindTheirValues() {
        ParsedSql parsed = NamedParameterUtils.parseSqlStatement(
                "SELECT * FROM t WHERE a = :PARAM.NOMBRE AND b = :CONTEXT.USER_ID");
        MapSqlParameterSource source = new MapSqlParameterSource()
                .addValue("PARAM.NOMBRE", "PRUEBA2025")
                .addValue("CONTEXT.USER_ID", 42L);

        Object[] values = NamedParameterUtils.buildValueArray(parsed, source, null);

        assertThat(values).containsExactly("PRUEBA2025", 42L);
    }

    @Test
    void substitutionProducesOnePlaceholderPerDottedName() {
        ParsedSql parsed = NamedParameterUtils.parseSqlStatement(
                "SELECT * FROM t WHERE a = :PARAM.NOMBRE");

        String sql = NamedParameterUtils.substituteNamedParameters(
                parsed, new MapSqlParameterSource("PARAM.NOMBRE", "x"));

        assertThat(sql).isEqualTo("SELECT * FROM t WHERE a = ?");
    }
}
