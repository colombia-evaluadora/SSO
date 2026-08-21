package com.co.eurekatic.common.query;

import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * V81 — {@link ParamConstraintValidator}. Cubre las seis reglas
 * (numéricas: positivo, decimales, cifras máximas; texto: numérico,
 * longitud mínima/máxima) y el caso "sin restricciones declaradas".
 */
class ParamConstraintValidatorTest {

    private static Map<String, Object> values(String key, Object val) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put(key, val);
        return m;
    }

    @Test
    void noConstraintsMeansNoViolations() {
        var violations = ParamConstraintValidator.validate(
                values("BODY.ID", -5), Map.of("BODY.ID", "BIGINT"), Map.of());
        assertThat(violations).isEmpty();
    }

    @Test
    void nullValueIsNeverAViolation() {
        Map<String, ParamConstraint> constraints = Map.of(
                "BODY.ID", new ParamConstraint(true, null, null, null, null, null, null, null));
        var values = new LinkedHashMap<String, Object>();
        values.put("BODY.ID", null);
        var violations = ParamConstraintValidator.validate(
                values, Map.of("BODY.ID", "BIGINT"), constraints);
        assertThat(violations).isEmpty();
    }

    @Test
    void onlyPositiveRejectsNegativeAndZero() {
        Map<String, ParamConstraint> constraints = Map.of(
                "BODY.EDAD", new ParamConstraint(true, null, null, null, null, null, null, null));
        var neg = ParamConstraintValidator.validate(
                values("BODY.EDAD", -1), Map.of("BODY.EDAD", "INTEGER"), constraints);
        assertThat(neg).containsKey("BODY.EDAD");
        assertThat(neg.get("BODY.EDAD")).contains("positivo");

        var zero = ParamConstraintValidator.validate(
                values("BODY.EDAD", 0), Map.of("BODY.EDAD", "INTEGER"), constraints);
        assertThat(zero).containsKey("BODY.EDAD");

        var ok = ParamConstraintValidator.validate(
                values("BODY.EDAD", 5), Map.of("BODY.EDAD", "INTEGER"), constraints);
        assertThat(ok).isEmpty();
    }

    @Test
    void allowDecimalsFalseRejectsDecimalValue() {
        Map<String, ParamConstraint> constraints = Map.of(
                "BODY.MONTO", new ParamConstraint(null, false, null, null, null, null, null, null));
        var bad = ParamConstraintValidator.validate(
                values("BODY.MONTO", new java.math.BigDecimal("10.5")),
                Map.of("BODY.MONTO", "NUMERIC"), constraints);
        assertThat(bad).containsKey("BODY.MONTO");
        assertThat(bad.get("BODY.MONTO")).contains("decimales");

        var ok = ParamConstraintValidator.validate(
                values("BODY.MONTO", new java.math.BigDecimal("10")),
                Map.of("BODY.MONTO", "NUMERIC"), constraints);
        assertThat(ok).isEmpty();
    }

    @Test
    void minMaxValueRejectOutOfRangeNumber() {
        // V83 — rango de VALOR, distinto de maxDigits (cifras, no
        // magnitud): teval_docente_detalle.valoracion en el schema
        // real es CHECK (valoracion >= 0 AND valoracion <= 100).
        Map<String, ParamConstraint> constraints = Map.of(
                "BODY.VALORACION", new ParamConstraint(
                        null, null, null,
                        new java.math.BigDecimal("0"), new java.math.BigDecimal("100"),
                        null, null, null));

        var tooLow = ParamConstraintValidator.validate(
                values("BODY.VALORACION", -1), Map.of("BODY.VALORACION", "NUMERIC"), constraints);
        assertThat(tooLow.get("BODY.VALORACION")).contains("mayor o igual que 0");

        var tooHigh = ParamConstraintValidator.validate(
                values("BODY.VALORACION", 150), Map.of("BODY.VALORACION", "NUMERIC"), constraints);
        assertThat(tooHigh.get("BODY.VALORACION")).contains("menor o igual que 100");

        var ok = ParamConstraintValidator.validate(
                values("BODY.VALORACION", 75), Map.of("BODY.VALORACION", "NUMERIC"), constraints);
        assertThat(ok).isEmpty();

        // Límites inclusive.
        var atBounds = ParamConstraintValidator.validate(
                values("BODY.VALORACION", 0), Map.of("BODY.VALORACION", "NUMERIC"), constraints);
        assertThat(atBounds).isEmpty();
    }

    @Test
    void maxDigitsRejectsExcessSignificantDigits() {
        Map<String, ParamConstraint> constraints = Map.of(
                "BODY.CODIGO", new ParamConstraint(null, null, 4, null, null, null, null, null));
        var bad = ParamConstraintValidator.validate(
                values("BODY.CODIGO", 123456L), Map.of("BODY.CODIGO", "BIGINT"), constraints);
        assertThat(bad).containsKey("BODY.CODIGO");
        assertThat(bad.get("BODY.CODIGO")).contains("4");

        var ok = ParamConstraintValidator.validate(
                values("BODY.CODIGO", 1234L), Map.of("BODY.CODIGO", "BIGINT"), constraints);
        assertThat(ok).isEmpty();
    }

    @Test
    void numericTextRejectsNonDigitCharacters() {
        Map<String, ParamConstraint> constraints = Map.of(
                "BODY.DOC", new ParamConstraint(null, null, null, null, null, true, null, null));
        var bad = ParamConstraintValidator.validate(
                values("BODY.DOC", "12A34"), Map.of("BODY.DOC", "TEXT"), constraints);
        assertThat(bad).containsKey("BODY.DOC");

        var ok = ParamConstraintValidator.validate(
                values("BODY.DOC", "12345"), Map.of("BODY.DOC", "TEXT"), constraints);
        assertThat(ok).isEmpty();
    }

    @Test
    void lengthRulesRejectOutOfRangeText() {
        Map<String, ParamConstraint> constraints = Map.of(
                "BODY.NOMBRE", new ParamConstraint(null, null, null, null, null, null, 4, 8));
        var tooShort = ParamConstraintValidator.validate(
                values("BODY.NOMBRE", "ab"), Map.of("BODY.NOMBRE", "TEXT"), constraints);
        assertThat(tooShort.get("BODY.NOMBRE")).contains("4");

        var tooLong = ParamConstraintValidator.validate(
                values("BODY.NOMBRE", "abcdefghijk"), Map.of("BODY.NOMBRE", "TEXT"), constraints);
        assertThat(tooLong.get("BODY.NOMBRE")).contains("8");

        var ok = ParamConstraintValidator.validate(
                values("BODY.NOMBRE", "abcde"), Map.of("BODY.NOMBRE", "TEXT"), constraints);
        assertThat(ok).isEmpty();
    }

    @Test
    void mismatchedRuleAgainstTypeIsIgnored() {
        // Numeric rule declared but the base type is textual — the
        // write-time validation in sso-admin should have rejected
        // this combination already; the runtime validator just
        // ignores it defensively rather than crashing.
        Map<String, ParamConstraint> constraints = Map.of(
                "BODY.X", new ParamConstraint(true, null, null, null, null, null, null, null));
        var result = ParamConstraintValidator.validate(
                values("BODY.X", "hello"), Map.of("BODY.X", "TEXT"), constraints);
        assertThat(result).isEmpty();
    }

    @Test
    void multipleViolatingFieldsAreAllReported() {
        Map<String, ParamConstraint> constraints = new LinkedHashMap<>();
        constraints.put("BODY.EDAD", new ParamConstraint(true, null, null, null, null, null, null, null));
        constraints.put("BODY.DOC", new ParamConstraint(null, null, null, null, null, true, null, null));
        Map<String, Object> values = new LinkedHashMap<>();
        values.put("BODY.EDAD", -3);
        values.put("BODY.DOC", "12A");
        Map<String, String> types = new LinkedHashMap<>();
        types.put("BODY.EDAD", "INTEGER");
        types.put("BODY.DOC", "TEXT");

        var violations = ParamConstraintValidator.validate(values, types, constraints);
        assertThat(violations).containsKeys("BODY.EDAD", "BODY.DOC");
    }

    @Test
    void requiredSuffixOnDeclaredTypeIsStrippedBeforeCheckingBaseType() {
        Map<String, ParamConstraint> constraints = Map.of(
                "BODY.EDAD", new ParamConstraint(true, null, null, null, null, null, null, null));
        var violations = ParamConstraintValidator.validate(
                values("BODY.EDAD", -1), Map.of("BODY.EDAD", "INTEGER!"), constraints);
        assertThat(violations).containsKey("BODY.EDAD");
    }
}
