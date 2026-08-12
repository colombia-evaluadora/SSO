package com.co.eurekatic.common.query;

import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * V49-bis — tests del rewriter que inserta {@code cast(:PH as TIPO)} en el
 * SQL del catálogo. El rewriter es el pegamento entre la metadata del
 * catálogo ({@code QUERY.PARAM_TYPES}) y el runtime de bind (texto puro
 * que PG castea).
 *
 * <p>Cubre:
 * <ul>
 *   <li>Reemplazo simple de un placeholder tipado.</li>
 *   <li>Placeholders múltiples en el mismo SQL.</li>
 *   <li>Placeholders NO declarados — se quedan como :PH (la guardia runtime
 *       del QueryService ya rechazó el caso).</li>
 *   <li>Arrays — {@code BIGINT[]} → {@code cast(:PH as int8[])}.</li>
 *   <li>DOMAIN types — schema-qualified: {@code BOOL_SN} → {@code cast(:PH as academico_test.bool_sn)}.</li>
 *   <li>Ignora literales con comillas y comentarios.</li>
 *   <li>{@code paramTypes} vacío o null → SQL sin tocar (legacy).</li>
 * </ul>
 */
class SqlRewriterTest {

    @Test
    void rewritesSingleDeclaredPlaceholder() {
        Map<String, String> types = Map.of("PARAM.ID", "BIGINT");
        String sql = "SELECT * FROM fn(:PARAM.ID)";
        assertThat(SqlRewriter.rewrite(sql, types))
                .isEqualTo("SELECT * FROM fn(cast(:PARAM.ID as bigint))");
    }

    @Test
    void rewritesMultiplePlaceholdersInSameSql() {
        Map<String, String> types = Map.of(
                "PARAM.A", "INTEGER",
                "PARAM.B", "BIGINT",
                "BODY.NAME", "TEXT");
        String sql = "SELECT * FROM t WHERE a = :PARAM.A AND b > :PARAM.B AND name = :BODY.NAME";
        assertThat(SqlRewriter.rewrite(sql, types))
                .isEqualTo("SELECT * FROM t WHERE a = cast(:PARAM.A as integer) "
                        + "AND b > cast(:PARAM.B as bigint) "
                        + "AND name = cast(:BODY.NAME as text)");
    }

    @Test
    void undeclaredPlaceholderIsLeftUntouched() {
        // La guardia runtime ya rechazó este caso; el rewriter no toca
        // placeholders no declarados para no empeorar el error message.
        Map<String, String> types = Map.of("PARAM.A", "BIGINT");
        String sql = "SELECT * FROM t WHERE a = :PARAM.A AND b = :PARAM.B";
        assertThat(SqlRewriter.rewrite(sql, types))
                .isEqualTo("SELECT * FROM t WHERE a = cast(:PARAM.A as bigint) AND b = :PARAM.B");
    }

    @Test
    void rewritesArrayPlaceholder() {
        Map<String, String> types = Map.of("BODY.IDS", "BIGINT[]");
        String sql = "SELECT * FROM t WHERE id = ANY(:BODY.IDS)";
        assertThat(SqlRewriter.rewrite(sql, types))
                .isEqualTo("SELECT * FROM t WHERE id = ANY(cast(:BODY.IDS as int8[]))");
    }

    @Test
    void rewritesDomainTypeWithSchemaQualifiedName() {
        Map<String, String> types = Map.of("PARAM.ESTADO", "BOOL_SN");
        String sql = "SELECT * FROM t WHERE estado = :PARAM.ESTADO";
        assertThat(SqlRewriter.rewrite(sql, types))
                .isEqualTo("SELECT * FROM t WHERE estado = cast(:PARAM.ESTADO as academico_test.bool_sn)");
    }

    @Test
    void rewritesAllSixDomainTypes() {
        Map<String, String> types = Map.of(
                "PARAM.A", "BOOL_SN",
                "PARAM.B", "ESTADO_AI",
                "PARAM.C", "ESTADO_AC",
                "PARAM.D", "ESTADO_ACTIVO_INACTIVO",
                "PARAM.E", "NODO_CURRICULAR",
                "PARAM.F", "TITULACION_GRADO");
        String sql = "SELECT :PARAM.A, :PARAM.B, :PARAM.C, :PARAM.D, :PARAM.E, :PARAM.F";
        assertThat(SqlRewriter.rewrite(sql, types))
                .isEqualTo("SELECT cast(:PARAM.A as academico_test.bool_sn), "
                        + "cast(:PARAM.B as academico_test.estado_ai), "
                        + "cast(:PARAM.C as academico_test.estado_ac), "
                        + "cast(:PARAM.D as academico_test.estado_activo_inactivo), "
                        + "cast(:PARAM.E as academico_test.nodo_curricular), "
                        + "cast(:PARAM.F as academico_test.titulacion_grado)");
    }

    @Test
    void ignoresPlaceholderInsideSingleQuotedString() {
        Map<String, String> types = Map.of("PARAM.ID", "BIGINT");
        String sql = "SELECT ':PARAM.ID' AS literal, :PARAM.ID AS id";
        assertThat(SqlRewriter.rewrite(sql, types))
                .isEqualTo("SELECT ':PARAM.ID' AS literal, cast(:PARAM.ID as bigint) AS id");
    }

    @Test
    void ignoresPlaceholderInsideDoubleQuotedIdentifier() {
        Map<String, String> types = Map.of("PARAM.ID", "BIGINT");
        String sql = "SELECT \":PARAM.ID\" AS quoted_ident, :PARAM.ID AS id";
        assertThat(SqlRewriter.rewrite(sql, types))
                .isEqualTo("SELECT \":PARAM.ID\" AS quoted_ident, cast(:PARAM.ID as bigint) AS id");
    }

    @Test
    void ignoresPlaceholderInsideLineComment() {
        Map<String, String> types = Map.of("PARAM.ID", "BIGINT");
        String sql = "SELECT 1 -- :PARAM.ID\n FROM t WHERE id = :PARAM.ID";
        // El placeholder dentro del comentario se queda literal — cosmético,
        // PG no lo parsea porque está después de --.
        assertThat(SqlRewriter.rewrite(sql, types))
                .isEqualTo("SELECT 1 -- :PARAM.ID\n FROM t WHERE id = cast(:PARAM.ID as bigint)");
    }

    @Test
    void ignoresPlaceholderInsideBlockComment() {
        // Dentro de /* */ el placeholder NO se reescribe — el lexer lo
        // considera comentario y lo deja intacto. Cosmético para el lector
        // (la sintaxis SQL es la misma), pero importante para tests que
        // comparan strings exactos.
        Map<String, String> types = Map.of("PARAM.ID", "BIGINT");
        String sql = "SELECT /* :PARAM.ID */ 1 FROM t WHERE id = :PARAM.ID";
        assertThat(SqlRewriter.rewrite(sql, types))
                .isEqualTo("SELECT /* :PARAM.ID */ 1 FROM t WHERE id = cast(:PARAM.ID as bigint)");
    }

    @Test
    void handlesEscapedSingleQuote() {
        Map<String, String> types = Map.of("PARAM.ID", "BIGINT");
        // '' es un escape de ' dentro de un literal.
        String sql = "SELECT 'it''s :PARAM.ID' AS s, :PARAM.ID AS id";
        assertThat(SqlRewriter.rewrite(sql, types))
                .isEqualTo("SELECT 'it''s :PARAM.ID' AS s, cast(:PARAM.ID as bigint) AS id");
    }

    @Test
    void emptyOrNullParamTypesLeavesSqlUntouched() {
        String sql = "SELECT * FROM t WHERE id = :PARAM.ID";
        assertThat(SqlRewriter.rewrite(sql, null)).isEqualTo(sql);
        assertThat(SqlRewriter.rewrite(sql, Map.of())).isEqualTo(sql);
    }

    @Test
    void unknownDeclaredTypeLeavesPlaceholderUntouched() {
        // Tipo declarado pero no en PG_CAST_NAME — defensivo, no debería
        // pasar porque la validación al guardar lo rechaza.
        Map<String, String> types = new LinkedHashMap<>();
        types.put("PARAM.X", "OUT_OF_BAND_TYPE");
        String sql = "SELECT :PARAM.X";
        assertThat(SqlRewriter.rewrite(sql, types)).isEqualTo("SELECT :PARAM.X");
    }

    @Test
    void rewritesAllArrayTypes() {
        Map<String, String> types = Map.of(
                "PARAM.A", "TEXT[]",
                "PARAM.B", "BIGINT[]",
                "PARAM.C", "INTEGER[]",
                "PARAM.D", "NUMERIC[]",
                "PARAM.E", "BOOLEAN[]",
                "PARAM.F", "TIME[]");
        String sql = "SELECT :PARAM.A, :PARAM.B, :PARAM.C, :PARAM.D, :PARAM.E, :PARAM.F";
        assertThat(SqlRewriter.rewrite(sql, types))
                .isEqualTo("SELECT cast(:PARAM.A as text[]), cast(:PARAM.B as int8[]), "
                        + "cast(:PARAM.C as int4[]), cast(:PARAM.D as numeric[]), "
                        + "cast(:PARAM.E as bool[]), cast(:PARAM.F as time[])");
    }

    @Test
    void caseInsensitivePlaceholderKeyInParamTypes() {
        // Las keys en paramTypes vienen en MAYÚSCULAS por convención, pero el
        // rewriter normaliza por si acaso.
        Map<String, String> types = Map.of("param.id", "BIGINT");
        String sql = "SELECT :PARAM.ID";
        assertThat(SqlRewriter.rewrite(sql, types))
                .isEqualTo("SELECT cast(:PARAM.ID as bigint)");
    }

    @Test
    void placeholdersToRewriteReturnsDeclaredOnes() {
        Map<String, String> types = Map.of(
                "PARAM.A", "BIGINT",
                "PARAM.B", "TEXT");
        String sql = "SELECT :PARAM.A, :PARAM.B, :PARAM.C";
        assertThat(SqlRewriter.placeholdersToRewrite(sql, types))
                .containsExactlyInAnyOrder("PARAM.A", "PARAM.B");
    }
}