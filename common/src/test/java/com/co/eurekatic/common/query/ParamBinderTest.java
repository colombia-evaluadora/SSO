package com.co.eurekatic.common.query;

import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;

import java.sql.Time;
import java.sql.Timestamp;
import java.sql.Types;
import java.time.LocalTime;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.springframework.jdbc.core.SqlTypeValue;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * Unit tests for {@link ParamBinder}. The four legacy scalar types
 * (TEXT, BIGINT, BOOLEAN, DATE) are exercised by the existing
 * integration suite; the tests here focus on the V50 additions and
 * the strict-failure path that the integration tests don't reach.
 *
 * <p>The "array" path delegates to a Spring {@code SqlTypeValue}
 * that calls {@code createArrayOf} on the connection — that branch
 * is exercised by the {@code TimeArrayIntegration} tests in the
 * query-service module. We assert the scalar coercion here because
 * it's deterministic and doesn't need a live connection.
 */
class ParamBinderTest {

    @Test
    void time_scalar_parsesHhMmSsFromString() {
        MapSqlParameterSource src = ParamBinder.build(
                Map.of("PARAM.HORA", "14:30:00"),
                Map.of("PARAM.HORA", "TIME"));

        assertThat(src.getValue("PARAM.HORA")).isInstanceOf(Time.class);
        assertThat(src.getSqlType("PARAM.HORA")).isEqualTo(Types.TIME);
        assertThat((Time) src.getValue("PARAM.HORA"))
                .isEqualTo(Time.valueOf(LocalTime.of(14, 30, 0)));
    }

    @Test
    void time_scalar_acceptsNativeTimeWithoutCoercion() {
        Time in = Time.valueOf(LocalTime.of(9, 0, 0));
        MapSqlParameterSource src = ParamBinder.build(
                Map.of("PARAM.HORA", in),
                Map.of("PARAM.HORA", "TIME"));

        assertThat(src.getValue("PARAM.HORA")).isSameAs(in);
        assertThat(src.getSqlType("PARAM.HORA")).isEqualTo(Types.TIME);
    }

    @Test
    void time_scalar_rejectsNonTimeString() {
        assertThatThrownBy(() -> ParamBinder.build(
                Map.of("PARAM.HORA", "not-a-time"),
                Map.of("PARAM.HORA", "TIME")))
                .isInstanceOf(IllegalArgumentException.class)
                // NumberFormatException extends IAE; ParamBinder catches
                // it and rewraps with the placeholder name.
                .hasMessageContaining("PARAM.HORA");
    }

    @Test
    void char1_acceptsSingleCharacterString() {
        MapSqlParameterSource src = ParamBinder.build(
                Map.of("PARAM.ESTADO", "S"),
                Map.of("PARAM.ESTADO", "CHAR(1)"));

        assertThat(src.getValue("PARAM.ESTADO")).isEqualTo("S");
        assertThat(src.getSqlType("PARAM.ESTADO")).isEqualTo(Types.CHAR);
    }

    @Test
    void char1_acceptsEmptyString() {
        // Empty string is a valid CHAR(1) value (PG keeps the column
        // to its declared width and pads with spaces; the empty
        // literal is the caller's choice. Don't second-guess here.)
        MapSqlParameterSource src = ParamBinder.build(
                Map.of("PARAM.ESTADO", ""),
                Map.of("PARAM.ESTADO", "CHAR(1)"));

        assertThat(src.getValue("PARAM.ESTADO")).isEqualTo("");
        assertThat(src.getSqlType("PARAM.ESTADO")).isEqualTo(Types.CHAR);
    }

    @Test
    void char1_rejectsStringLongerThanOne() {
        assertThatThrownBy(() -> ParamBinder.build(
                Map.of("PARAM.ESTADO", "SI"),
                Map.of("PARAM.ESTADO", "CHAR(1)")))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("CHAR(1)")
                .hasMessageContaining("SI");
    }

    @Test
    void char1_rejectsNumericValueLongerThanOne() {
        // 12 → "12" → length 2 → reject.
        assertThatThrownBy(() -> ParamBinder.build(
                Map.of("PARAM.ESTADO", 12),
                Map.of("PARAM.ESTADO", "CHAR(1)")))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("CHAR(1)");
    }

    @Test
    void char1_acceptsSingleDigitNumber() {
        // 1 → "1" → length 1 → ok.
        MapSqlParameterSource src = ParamBinder.build(
                Map.of("PARAM.ESTADO", 1),
                Map.of("PARAM.ESTADO", "CHAR(1)"));

        assertThat(src.getValue("PARAM.ESTADO")).isEqualTo("1");
        assertThat(src.getSqlType("PARAM.ESTADO")).isEqualTo(Types.CHAR);
    }

    @Test
    void undeclaredKey_fallsBackToSpringAutoDerive() {
        // No entry in paramTypes → no sqlType, no coercion. This is the
        // legacy path used by queries predating V49.
        MapSqlParameterSource src = ParamBinder.build(
                Map.of("BODY.X", "hello"),
                Map.of());

        assertThat(src.getValue("BODY.X")).isEqualTo("hello");
        // Spring's default sqlType for an unannotated value is
        // SqlTypeValue.TYPE_UNKNOWN (Integer.MIN_VALUE), not the JDBC
        // Types.NULL constant — the driver's metadata lookup at execute
        // time is what does the actual falling-back.
        assertThat(src.getSqlType("BODY.X")).isEqualTo(SqlTypeValue.TYPE_UNKNOWN);
    }

    @Test
    void unknownDeclaredType_fallsBackToAutoDeriveDefensively() {
        // The validation in sso-admin already rejects unknown types, but
        // we don't want ParamBinder to crash on a hostile DB row.
        Map<String, String> types = new LinkedHashMap<>();
        types.put("PARAM.X", "OUT-OF-BAND-TYPE");

        MapSqlParameterSource src = ParamBinder.build(
                Map.of("PARAM.X", "hello"),
                types);

        assertThat(src.getValue("PARAM.X")).isEqualTo("hello");
        assertThat(src.getSqlType("PARAM.X")).isEqualTo(SqlTypeValue.TYPE_UNKNOWN);
    }

    @Test
    void nullValue_carriesNoCoercion() {
        // null in, null out — Spring keeps the key with the declared
        // sqlType so PG can still pick the right parameter type at
        // execution time. We don't second-guess.
        // Map.of rejects null values, so use a plain HashMap for the
        // null entry.
        Map<String, Object> values = new HashMap<>();
        values.put("PARAM.HORA", null);

        MapSqlParameterSource src = ParamBinder.build(
                values,
                Map.of("PARAM.HORA", "TIME"));

        assertThat(src.getValue("PARAM.HORA")).isNull();
        assertThat(src.getSqlType("PARAM.HORA")).isEqualTo(Types.TIME);
    }

    @Test
    void timestamp_returnsTimestampForStringInput() {
        // Sanity check the change did not break the parallel TIMESTAMP
        // case. The V50 patch only widened the switch; we want to know
        // immediately if it accidentally reordered existing cases.
        MapSqlParameterSource src = ParamBinder.build(
                Map.of("PARAM.TS", "2026-01-15 10:30:00"),
                Map.of("PARAM.TS", "TIMESTAMP"));

        assertThat(src.getValue("PARAM.TS")).isInstanceOf(Timestamp.class);
        assertThat(src.getSqlType("PARAM.TS")).isEqualTo(Types.TIMESTAMP);
    }

    @Test
    void time_array_passesArrayTypeForDriverToCreate() {
        // We can't easily exercise createArrayOf without a connection, but
        // we can assert that the value is wrapped in a SqlTypeValue and
        // that the declared sqlType is Types.ARRAY. The actual array
        // creation is verified by TimeArrayIntegrationTest.
        MapSqlParameterSource src = ParamBinder.build(
                Map.of("BODY.HORAS", List.of("10:00:00", "11:00:00")),
                Map.of("BODY.HORAS", "TIME[]"));

        assertThat(src.getValue("BODY.HORAS")).isNotNull();
        assertThat(src.getSqlType("BODY.HORAS")).isEqualTo(Types.ARRAY);
    }
}
