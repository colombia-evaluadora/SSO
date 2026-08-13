package com.co.eurekatic.common.query;

import org.junit.jupiter.api.Nested;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.SqlTypeValue;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.sql.Time;
import java.sql.Timestamp;
import java.sql.Types;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * V49-bis — tests del binder que serializa cada valor a String para que
 * PG aplique el cast en SQL (via {@link SqlRewriter}). El binder ya NO
 * usa {@code addValue(k, v, sqlType)} en el camino normal — eso era la
 * causa del bug del operador (driver JDBC no conocía los DOMAIN types).
 *
 * <p>Casos cubiertos:
 * <ul>
 *   <li>Escalares: String, Long, Integer, BigDecimal, Boolean, Date, Time,
 *       Timestamp, UUID → serialización a String.</li>
 *   <li>Arrays: List de escalares → texto PG-array con quoting correcto.</li>
 *   <li>DOMAIN types (BOOL_SN, etc.) → serialización a String; el cast
 *       corre en SQL (insertado por SqlRewriter).</li>
 *   <li>BODY_RAW con Map → JSON literal que se castea via jsonb en SQL.</li>
 *   <li>null → no se bindea la key.</li>
 *   <li>Tipo declarado pero desconocido → defensivo, no crashea.</li>
 * </ul>
 */
class ParamBinderTest {

    @Test
    void stringValueIsBoundAsString() {
        MapSqlParameterSource src = ParamBinder.build(
                Map.of("PARAM.NOMBRE", "alice"),
                Map.of("PARAM.NOMBRE", "TEXT"));
        assertThat(src.getValue("PARAM.NOMBRE")).isEqualTo("alice");
        // Spring's addValue sin sqlType pone TYPE_UNKNOWN — el cast corre en SQL.
        assertThat(src.getSqlType("PARAM.NOMBRE")).isEqualTo(SqlTypeValue.TYPE_UNKNOWN);
    }

    @Test
    void longValueIsBoundAsTextRepresentation() {
        // El cast a bigint corre en SQL (insertado por SqlRewriter).
        MapSqlParameterSource src = ParamBinder.build(
                Map.of("PARAM.ID", 1432L),
                Map.of("PARAM.ID", "BIGINT"));
        assertThat(src.getValue("PARAM.ID")).isEqualTo("1432");
    }

    @Test
    void integerValueIsBoundAsTextRepresentation() {
        MapSqlParameterSource src = ParamBinder.build(
                Map.of("PARAM.ID", 42),
                Map.of("PARAM.ID", "INTEGER"));
        assertThat(src.getValue("PARAM.ID")).isEqualTo("42");
    }

    @Test
    void bigDecimalValueIsBoundAsPlainString() {
        // toPlainString — sin notación científica, PG parsea numeric correctamente.
        MapSqlParameterSource src = ParamBinder.build(
                Map.of("PARAM.PRECIO", new BigDecimal("1234.5600")),
                Map.of("PARAM.PRECIO", "NUMERIC"));
        assertThat(src.getValue("PARAM.PRECIO")).isEqualTo("1234.5600");
    }

    @Test
    void booleanValueIsBoundAsTrueFalseString() {
        MapSqlParameterSource src = ParamBinder.build(
                Map.of("PARAM.ACTIVO", true),
                Map.of("PARAM.ACTIVO", "BOOLEAN"));
        assertThat(src.getValue("PARAM.ACTIVO")).isEqualTo("true");
    }

    @Test
    void sqlDateIsBoundAsIsoString() {
        java.sql.Date d = java.sql.Date.valueOf("2026-08-12");
        MapSqlParameterSource src = ParamBinder.build(
                Map.of("PARAM.FECHA", d),
                Map.of("PARAM.FECHA", "DATE"));
        assertThat(src.getValue("PARAM.FECHA")).isEqualTo("2026-08-12");
    }

    @Test
    void sqlTimeIsBoundAsIsoString() {
        Time t = Time.valueOf("14:30:00");
        MapSqlParameterSource src = ParamBinder.build(
                Map.of("PARAM.HORA", t),
                Map.of("PARAM.HORA", "TIME"));
        assertThat(src.getValue("PARAM.HORA")).isEqualTo("14:30:00");
    }

    @Test
    void sqlTimestampIsBoundAsIsoString() {
        Timestamp ts = Timestamp.valueOf("2026-08-12 14:30:00.123");
        MapSqlParameterSource src = ParamBinder.build(
                Map.of("PARAM.TS", ts),
                Map.of("PARAM.TS", "TIMESTAMP"));
        assertThat(src.getValue("PARAM.TS")).isEqualTo("2026-08-12 14:30:00.123");
    }

    @Test
    void uuidValueIsBoundAsString() {
        java.util.UUID u = java.util.UUID.fromString("550e8400-e29b-41d4-a716-446655440000");
        MapSqlParameterSource src = ParamBinder.build(
                Map.of("PARAM.ID", u),
                Map.of("PARAM.ID", "UUID"));
        assertThat(src.getValue("PARAM.ID")).isEqualTo("550e8400-e29b-41d4-a716-446655440000");
    }

    @Test
    void domainTypeIsBoundAsString() {
        // BOOL_SN acepta sólo 'S'/'N'. Pasamos 'S' como String — el cast
        // academico_test.bool_sn validará contra el CHECK constraint.
        MapSqlParameterSource src = ParamBinder.build(
                Map.of("PARAM.ESTADO", "S"),
                Map.of("PARAM.ESTADO", "BOOL_SN"));
        assertThat(src.getValue("PARAM.ESTADO")).isEqualTo("S");
    }

    @Test
    void undeclaredKeyIsBoundAsStringifiedValue() {
        // Sin tipo declarado — SqlRewriter no insertó cast. El binder
        // serializa a texto. La guardia runtime del QueryService ya
        // rechazó este caso, pero si llegamos aquí, no crasheamos.
        MapSqlParameterSource src = ParamBinder.build(
                Map.of("BODY.X", "hello"),
                Map.of());
        assertThat(src.getValue("BODY.X")).isEqualTo("hello");
    }

    @Test
    void unknownDeclaredTypeIsBoundAsStringifiedValueDefensively() {
        Map<String, String> types = new LinkedHashMap<>();
        types.put("PARAM.X", "OUT-OF-BAND-TYPE");

        MapSqlParameterSource src = ParamBinder.build(
                Map.of("PARAM.X", "hello"),
                types);
        assertThat(src.getValue("PARAM.X")).isEqualTo("hello");
    }

    @Test
    void nullValueIsNotBound() {
        // null in, null out: no se añade la key al MapSqlParameterSource.
        // El placeholder en el SQL no se bindea — depende del autor usar
        // coalesce(:var, default) en el SQL si quiere default.
        Map<String, Object> values = new HashMap<>();
        values.put("PARAM.HORA", null);

        MapSqlParameterSource src = ParamBinder.build(
                values,
                Map.of("PARAM.HORA", "TIME"));
        assertThat(src.hasValue("PARAM.HORA")).isFalse();
    }

    @Test
    void emptyListBecomesEmptyPgArray() {
        MapSqlParameterSource src = ParamBinder.build(
                Map.of("BODY.IDS", List.of()),
                Map.of("BODY.IDS", "BIGINT[]"));
        assertThat(src.getValue("BODY.IDS")).isEqualTo("{}");
    }

    @Test
    void listOfLongsBecomesInt8ArrayLiteral() {
        MapSqlParameterSource src = ParamBinder.build(
                Map.of("BODY.IDS", List.of(1L, 2L, 3L)),
                Map.of("BODY.IDS", "BIGINT[]"));
        assertThat(src.getValue("BODY.IDS")).isEqualTo("{1,2,3}");
    }

    @Test
    void listOfStringsIsQuotedWithEscaping() {
        MapSqlParameterSource src = ParamBinder.build(
                Map.of("BODY.NAMES", List.of("alice", "bob's", "carol")),
                Map.of("BODY.NAMES", "TEXT[]"));
        // PG array syntax: dentro de "..." sólo se escapan " y \.
        // Las comillas simples van literales (no necesitan escape).
        assertThat(src.getValue("BODY.NAMES")).isEqualTo("{\"alice\",\"bob's\",\"carol\"}");
    }

    @Test
    void listOfStringsEscapesDoubleQuotesAndBackslash() {
        MapSqlParameterSource src = ParamBinder.build(
                Map.of("BODY.NAMES", List.of("a\"b", "c\\d")),
                Map.of("BODY.NAMES", "TEXT[]"));
        assertThat(src.getValue("BODY.NAMES")).isEqualTo("{\"a\\\"b\",\"c\\\\d\"}");
    }

    @Test
    void listOfBooleansBecomesBoolArrayLiteral() {
        MapSqlParameterSource src = ParamBinder.build(
                Map.of("BODY.FLAGS", List.of(true, false, true)),
                Map.of("BODY.FLAGS", "BOOLEAN[]"));
        assertThat(src.getValue("BODY.FLAGS")).isEqualTo("{true,false,true}");
    }

    @Test
    void listWithNullElementsRendersAsNull() {
        Map<String, Object> values = new HashMap<>();
        values.put("BODY.IDS", java.util.Arrays.asList(1L, null, 3L));
        MapSqlParameterSource src = ParamBinder.build(
                values,
                Map.of("BODY.IDS", "BIGINT[]"));
        assertThat(src.getValue("BODY.IDS")).isEqualTo("{1,NULL,3}");
    }

    @Test
    void listOfIsoTimeStringsBecomesTimeArrayLiteral() {
        // JSON no tiene un literal nativo de hora — Jackson SIEMPRE entrega
        // String para cada elemento (p.ej. "10:00:00"), nunca java.sql.Time.
        // Antes de este fix, validateAgainstDeclared exigía instanceof Time
        // en cada elemento y rechazaba cualquier body JSON válido para TIME[].
        MapSqlParameterSource src = ParamBinder.build(
                Map.of("BODY.DESCANSO_INICIO", List.of("10:00:00")),
                Map.of("BODY.DESCANSO_INICIO", "TIME[]"));
        assertThat(src.getValue("BODY.DESCANSO_INICIO")).isEqualTo("{\"10:00:00\"}");
    }

    @Test
    void listOfIsoDateStringsBecomesDateArrayLiteral() {
        // Mismo motivo que TIME[]: JSON no tiene literal nativo de fecha,
        // Jackson entrega String para cada elemento.
        MapSqlParameterSource src = ParamBinder.build(
                Map.of("BODY.FERIADOS", List.of("2026-01-01", "2026-12-25")),
                Map.of("BODY.FERIADOS", "DATE[]"));
        assertThat(src.getValue("BODY.FERIADOS")).isEqualTo("{\"2026-01-01\",\"2026-12-25\"}");
    }

    @Test
    void listOfIsoTimestampStringsBecomesTimestampArrayLiteral() {
        MapSqlParameterSource src = ParamBinder.build(
                Map.of("BODY.CORTES", List.of("2026-08-12 14:30:00")),
                Map.of("BODY.CORTES", "TIMESTAMP[]"));
        assertThat(src.getValue("BODY.CORTES")).isEqualTo("{\"2026-08-12 14:30:00\"}");
    }

    @Test
    void listOfIsoTimestampTzStringsBecomesTimestampTzArrayLiteral() {
        MapSqlParameterSource src = ParamBinder.build(
                Map.of("BODY.CORTES", List.of("2026-08-12T14:30:00-05:00")),
                Map.of("BODY.CORTES", "TIMESTAMPTZ[]"));
        assertThat(src.getValue("BODY.CORTES")).isEqualTo("{\"2026-08-12T14:30:00-05:00\"}");
    }

    @Test
    void bodyRawMapBecomesJsonLiteral() {
        Map<String, Object> filtro = new LinkedHashMap<>();
        filtro.put("zona", 1);
        filtro.put("activo", true);

        MapSqlParameterSource src = ParamBinder.build(
                Map.of("BODY_RAW.FILTRO", filtro),
                Map.of("BODY_RAW.FILTRO", "JSONB"));
        // El cast academico_test.jsonb (o jsonb built-in) acepta el JSON literal.
        assertThat(src.getValue("BODY_RAW.FILTRO"))
                .isEqualTo("{\"zona\":1,\"activo\":true}");
    }

    @Test
    void bodyRawMapWithNestedStructures() {
        Map<String, Object> filtro = new LinkedHashMap<>();
        filtro.put("rango", List.of(1, 2, 3));
        Map<String, Object> inner = new LinkedHashMap<>();
        inner.put("k", "v");
        filtro.put("meta", inner);

        MapSqlParameterSource src = ParamBinder.build(
                Map.of("BODY_RAW.FILTRO", filtro),
                Map.of("BODY_RAW.FILTRO", "JSONB"));
        assertThat(src.getValue("BODY_RAW.FILTRO"))
                .isEqualTo("{\"rango\":[1,2,3],\"meta\":{\"k\":\"v\"}}");
    }

    @Test
    void bodyRawMapWithSpecialCharsEscapesCorrectly() {
        Map<String, Object> filtro = new LinkedHashMap<>();
        filtro.put("msg", "hello \"world\"\nnext line");

        MapSqlParameterSource src = ParamBinder.build(
                Map.of("BODY_RAW.FILTRO", filtro),
                Map.of("BODY_RAW.FILTRO", "JSONB"));
        assertThat(src.getValue("BODY_RAW.FILTRO"))
                .isEqualTo("{\"msg\":\"hello \\\"world\\\"\\nnext line\"}");
    }

    @Test
    void arrayRejectsNonListNonArrayValueWithClearMessage() {
        Map<String, Object> values = new HashMap<>();
        values.put("BODY.IDS", "not-a-list");
        assertThatThrownBy(() ->
                ParamBinder.build(values, Map.of("BODY.IDS", "BIGINT[]")))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("BODY.IDS")
                .hasMessageContaining("BIGINT[]");
    }

    /**
     * V60 — los overloads {@code buildStrict} introducen
     * validación de tipo entre el valor Java y el declarado.
     * Estos casos documentan el contrato del guardia runtime
     * para cada categoría de tipo.
     */
    @Nested
    class StrictTypeValidation {

        @Test
        void booleanParamRejectsStringValue() {
            Map<String, Object> values = new LinkedHashMap<>();
            values.put("PARAM.ACTIVO", "S");
            assertThatThrownBy(() -> ParamBinder.buildStrict(values,
                    Map.of("PARAM.ACTIVO", "BOOLEAN"), Map.of()))
                    .isInstanceOf(IllegalArgumentException.class)
                    .hasMessageContaining("BOOLEAN")
                    .hasMessageContaining("PARAM.ACTIVO");
        }

        @Test
        void booleanParamAcceptsBooleanValue() {
            Map<String, Object> values = new LinkedHashMap<>();
            values.put("PARAM.ACTIVO", true);
            assertThat(ParamBinder.buildStrict(values,
                    Map.of("PARAM.ACTIVO", "BOOLEAN"), Map.of()))
                    .isNotNull();
        }

        @Test
        void bigIntParamRejectsDouble() {
            Map<String, Object> values = new LinkedHashMap<>();
            values.put("PARAM.ID", 3.14);
            assertThatThrownBy(() -> ParamBinder.buildStrict(values,
                    Map.of("PARAM.ID", "BIGINT"), Map.of()))
                    .isInstanceOf(IllegalArgumentException.class)
                    .hasMessageContaining("BIGINT")
                    .hasMessageContaining("PARAM.ID")
                    .hasMessageContaining("Double");
        }

        @Test
        void bigIntParamAcceptsIntegerLongAndBigInteger() {
            for (Object v : new Object[]{42, 42L, BigInteger.valueOf(42)}) {
                Map<String, Object> values = new LinkedHashMap<>();
                values.put("PARAM.ID", v);
                assertThat(ParamBinder.buildStrict(values,
                        Map.of("PARAM.ID", "BIGINT"), Map.of()))
                        .as("acepta %s como BIGINT", v.getClass().getSimpleName())
                        .isNotNull();
            }
        }

        @Test
        void bigIntParamAcceptsParseableString() {
            // Caso típico de cliente que serializa el id como
            // "12345" en vez de 12345 — PG lo aceptaría vía
            // el cast, así que tampoco rechazamos en el
            // guardia. (Si fuera "abc", también pasaría el
            // guardia y PG devolvería SQLSTATE 22P02 — ese
            // caso el guardia no lo cubre porque añadir
            // parseo+redondeo aquí duplica trabajo con PG.)
            Map<String, Object> values = new LinkedHashMap<>();
            values.put("PARAM.ID", "12345");
            assertThat(ParamBinder.buildStrict(values,
                    Map.of("PARAM.ID", "BIGINT"), Map.of())).isNotNull();
        }

        @Test
        void numericParamAcceptsDecimals() {
            Map<String, Object> values = new LinkedHashMap<>();
            values.put("PARAM.PRECIO", new BigDecimal("1234.5600"));
            assertThat(ParamBinder.buildStrict(values,
                    Map.of("PARAM.PRECIO", "NUMERIC"), Map.of())).isNotNull();
        }

        @Test
        void arrayParamRejectsMixedTypes() {
            // El caso del log: el cliente envía [1, "2", 3].
            // El catálogo lo declara BIGINT[]; el guardia
            // detecta el String en el índice 1 y nombra
            // exactamente qué elemento falla.
            Map<String, Object> values = new LinkedHashMap<>();
            values.put("BODY.IDS", List.of(1L, "2", 3L));
            assertThatThrownBy(() -> ParamBinder.buildStrict(values,
                    Map.of("BODY.IDS", "BIGINT[]"), Map.of()))
                    .isInstanceOf(IllegalArgumentException.class)
                    .hasMessageContaining("BODY.IDS")
                    .hasMessageContaining("[1]")
                    .hasMessageContaining("String");
        }

        @Test
        void arrayParamAcceptsUniformIntegers() {
            Map<String, Object> values = new LinkedHashMap<>();
            values.put("BODY.IDS", List.of(1L, 2L, 3L));
            assertThat(ParamBinder.buildStrict(values,
                    Map.of("BODY.IDS", "BIGINT[]"), Map.of())).isNotNull();
        }

        @Test
        void arrayParamRejectsScalarWhereArrayExpected() {
            // "x": 5 debería ser BIGINT, no un array — el
            // guardia lo rechaza si el tipo declarado es
            // BIGINT[] y el valor es escalar.
            Map<String, Object> values = new LinkedHashMap<>();
            values.put("BODY.IDS", 5);
            assertThatThrownBy(() -> ParamBinder.buildStrict(values,
                    Map.of("BODY.IDS", "BIGINT[]"), Map.of()))
                    .isInstanceOf(IllegalArgumentException.class)
                    .hasMessageContaining("BODY.IDS")
                    .hasMessageContaining("array");
        }

        @Test
        void jsonbParamAcceptsValidJsonLiteralAsString() {
            // El guardia NO parsea el String — acepta un JSON
            // literal textual (lo que el cliente suele enviar)
            // y deja que PG valide al aplicar el cast. Un
            // String inválido también pasa el guardia y PG lo
            // rechaza con SQLSTATE 22P02 — eso es aceptable
            // porque la causa raíz está clara: el cliente
            // mandó algo que no era JSON.
            Map<String, Object> values = new LinkedHashMap<>();
            values.put("BODY_RAW.FILTRO", "{\"x\":1}");
            assertThat(ParamBinder.buildStrict(values,
                    Map.of("BODY_RAW.FILTRO", "JSONB"), Map.of())).isNotNull();
        }

        @Test
        void jsonbParamAcceptsMap() {
            Map<String, Object> values = new LinkedHashMap<>();
            values.put("BODY_RAW.FILTRO", Map.of("x", 1));
            assertThat(ParamBinder.buildStrict(values,
                    Map.of("BODY_RAW.FILTRO", "JSONB"), Map.of())).isNotNull();
        }

        @Test
        void undeclaredKeyDoesNotTriggerValidation() {
            // Sin tipo declarado, buildStrict no impone
            // validación — reproduce el comportamiento legacy.
            Map<String, Object> values = new LinkedHashMap<>();
            values.put("BODY.X", "hola");
            assertThat(ParamBinder.buildStrict(values, Map.of(), Map.of())).isNotNull();
        }

        @Test
        void extraDeclaredTypesSupplementBaseMap() {
            // extraDeclared añade tipos que no están en
            // paramTypes — útil cuando el caller computó
            // tipos por su cuenta (p.ej. desde un JsonNode
            // tree durante el path dispatch).
            Map<String, Object> values = new LinkedHashMap<>();
            values.put("BODY.NEW", "true-not-a-bool");
            assertThatThrownBy(() -> ParamBinder.buildStrict(
                    values, Map.of(), Map.of("BODY.NEW", "BOOLEAN")))
                    .isInstanceOf(IllegalArgumentException.class)
                    .hasMessageContaining("BOOLEAN");
        }
    }
}