package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.common.entity.ExecutionMode;
import com.co.eurekatic.common.query.ParamConstraint;
import com.co.eurekatic.ssoadmin.dto.QueryRequest;
import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;

/**
 * V70 — verifica {@code QueryAdminService.validateParamConstraints}.
 * Misma técnica de invocación por reflexión que
 * {@link QueryAdminServiceParamTypesValidationTest}: la validación es
 * private y no queremos arrastrar toda la cadena de {@code create}.
 */
class QueryAdminServiceParamConstraintsValidationTest {

    private QueryAdminService service() {
        com.co.eurekatic.common.repository.QueryRepository queryRepo =
                mock(com.co.eurekatic.common.repository.QueryRepository.class);
        com.co.eurekatic.common.repository.RoleRepository roleRepo =
                mock(com.co.eurekatic.common.repository.RoleRepository.class);
        com.co.eurekatic.common.repository.MicroserviceRepository microserviceRepo =
                mock(com.co.eurekatic.common.repository.MicroserviceRepository.class);
        PathRegistryNotifier notifier = mock(PathRegistryNotifier.class);
        return new QueryAdminService(queryRepo, roleRepo, microserviceRepo, notifier);
    }

    private void invokeValidation(QueryRequest req) {
        try {
            var method = QueryAdminService.class.getDeclaredMethod(
                    "validateParamConstraints", QueryRequest.class);
            method.setAccessible(true);
            method.invoke(service(), req);
        } catch (ReflectiveOperationException e) {
            if (e.getCause() instanceof RuntimeException re) throw re;
            if (e.getCause() instanceof Exception ex) throw new RuntimeException(ex);
            throw new RuntimeException(e);
        }
    }

    private QueryRequest req(Map<String, String> paramTypes, Map<String, ParamConstraint> constraints) {
        return new QueryRequest(null, null,
                "SELECT 1 WHERE id = :BODY.ID",
                null, false, false, null, null, null, null,
                null, ExecutionMode.SELECT, null, "POST",
                paramTypes, constraints);
    }

    @Test
    void emptyConstraintsPass() {
        assertThatCode(() -> invokeValidation(req(Map.of("BODY.ID", "BIGINT"), Map.of())))
                .doesNotThrowAnyException();
    }

    @Test
    void numericRulesOnDeclaredIntegerTypePass() {
        Map<String, ParamConstraint> constraints = new LinkedHashMap<>();
        constraints.put("BODY.ID", new ParamConstraint(true, false, 6, null, null, null, null, null));
        assertThatCode(() -> invokeValidation(req(Map.of("BODY.ID", "BIGINT"), constraints)))
                .doesNotThrowAnyException();
    }

    @Test
    void textRulesOnDeclaredTextTypePass() {
        Map<String, ParamConstraint> constraints = new LinkedHashMap<>();
        constraints.put("BODY.ID", new ParamConstraint(null, null, null, null, null, true, 4, 12));
        assertThatCode(() -> invokeValidation(req(Map.of("BODY.ID", "TEXT"), constraints)))
                .doesNotThrowAnyException();
    }

    @Test
    void rejectsConstraintOnUndeclaredParam() {
        Map<String, ParamConstraint> constraints = new LinkedHashMap<>();
        constraints.put("BODY.MISSING", new ParamConstraint(true, null, null, null, null, null, null, null));
        assertThatThrownBy(() -> invokeValidation(req(Map.of("BODY.ID", "BIGINT"), constraints)))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("BODY.MISSING")
                .hasMessageContaining("PARAM_TYPES");
    }

    @Test
    void rejectsNumericRuleOnTextType() {
        Map<String, ParamConstraint> constraints = new LinkedHashMap<>();
        constraints.put("BODY.ID", new ParamConstraint(true, null, null, null, null, null, null, null));
        assertThatThrownBy(() -> invokeValidation(req(Map.of("BODY.ID", "TEXT"), constraints)))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("numéricas");
    }

    @Test
    void rejectsTextRuleOnNumericType() {
        Map<String, ParamConstraint> constraints = new LinkedHashMap<>();
        constraints.put("BODY.ID", new ParamConstraint(null, null, null, null, null, null, 4, 12));
        assertThatThrownBy(() -> invokeValidation(req(Map.of("BODY.ID", "BIGINT"), constraints)))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("texto");
    }

    @Test
    void rejectsNonPositiveMaxDigits() {
        Map<String, ParamConstraint> constraints = new LinkedHashMap<>();
        constraints.put("BODY.ID", new ParamConstraint(null, null, 0, null, null, null, null, null));
        assertThatThrownBy(() -> invokeValidation(req(Map.of("BODY.ID", "BIGINT"), constraints)))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("maxDigits");
    }

    @Test
    void rejectsMinLengthGreaterThanMaxLength() {
        Map<String, ParamConstraint> constraints = new LinkedHashMap<>();
        constraints.put("BODY.ID", new ParamConstraint(null, null, null, null, null, null, 10, 4));
        assertThatThrownBy(() -> invokeValidation(req(Map.of("BODY.ID", "TEXT"), constraints)))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("minLength");
    }

    @Test
    void rejectsNegativeMinLength() {
        Map<String, ParamConstraint> constraints = new LinkedHashMap<>();
        constraints.put("BODY.ID", new ParamConstraint(null, null, null, null, null, null, -1, null));
        assertThatThrownBy(() -> invokeValidation(req(Map.of("BODY.ID", "TEXT"), constraints)))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("minLength");
    }

    @Test
    void minMaxValueOnDeclaredNumericTypePasses() {
        Map<String, ParamConstraint> constraints = new LinkedHashMap<>();
        constraints.put("BODY.VALORACION", new ParamConstraint(null, null, null,
                java.math.BigDecimal.ZERO, java.math.BigDecimal.valueOf(100), null, null, null));
        assertThatCode(() -> invokeValidation(req(Map.of("BODY.VALORACION", "NUMERIC"), constraints)))
                .doesNotThrowAnyException();
    }

    @Test
    void rejectsMinValueGreaterThanMaxValue() {
        Map<String, ParamConstraint> constraints = new LinkedHashMap<>();
        constraints.put("BODY.ID", new ParamConstraint(null, null, null,
                java.math.BigDecimal.valueOf(10), java.math.BigDecimal.valueOf(4), null, null, null));
        assertThatThrownBy(() -> invokeValidation(req(Map.of("BODY.ID", "BIGINT"), constraints)))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("minValue");
    }

    @Test
    void rejectsMinValueOnTextType() {
        Map<String, ParamConstraint> constraints = new LinkedHashMap<>();
        constraints.put("BODY.ID", new ParamConstraint(null, null, null,
                java.math.BigDecimal.ZERO, null, null, null, null));
        assertThatThrownBy(() -> invokeValidation(req(Map.of("BODY.ID", "TEXT"), constraints)))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("numéricas");
    }
}
