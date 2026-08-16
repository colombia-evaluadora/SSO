package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.common.entity.ExecutionMode;
import com.co.eurekatic.common.query.ParamTypes;
import com.co.eurekatic.ssoadmin.dto.QueryRequest;
import org.junit.jupiter.api.Test;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.LinkedHashMap;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;

/**
 * V60-bis — verifies the strict validation that lives at
 * {@link QueryAdminService#create(QueryRequest)} (and is
 * shared with update).
 *
 * <p>The validation is private, so the test exercises it by
 * calling {@code create} with a constructed
 * {@link QueryRequest}. Where the validation is the only
 * thing that runs (everything else fails first on missing
 * collaborators), the assertions catch the IllegalArgumentException
 * before collaborators get exercised.
 *
 * <p>What the validation guarantees:
 * <ul>
 *   <li>DOMAIN types of {@code academico_test} are now in
 *       {@link ParamTypes#CURATED}, so the sso-admin no
 *       longer rejects {@code BOOL_SN} et al.</li>
 *   <li>Every key in paramTypes is a valid placeholder
 *       name (uppercase ASCII, namespace-prefixed).</li>
 *   <li>Lowercase keys are canonicalized silently — the
 *       admin UI is now case-tolerant.</li>
 *   <li>Two keys that differ only by case map to the same
 *       canonical name are rejected.</li>
 *   <li>Every {@code :PARAM.*}, {@code :BODY.*},
 *       {@code :BODY_RAW.*} placeholder in the SQL has a
 *       matching entry in paramTypes.</li>
 * </ul>
 *
 * <p>{@code :CONTEXT.*} and {@code :QUERY.{SIZE,OFFSET}}
 * are system-injected and need no entry.
 */
class QueryAdminServiceParamTypesValidationTest {

    private QueryAdminService service() {
        com.co.eurekatic.common.repository.QueryRepository queryRepo = mock(com.co.eurekatic.common.repository.QueryRepository.class);
        com.co.eurekatic.common.repository.RoleRepository roleRepo = mock(com.co.eurekatic.common.repository.RoleRepository.class);
        com.co.eurekatic.common.repository.MicroserviceRepository microserviceRepo = mock(com.co.eurekatic.common.repository.MicroserviceRepository.class);
        PathRegistryNotifier notifier = mock(PathRegistryNotifier.class);
        return new QueryAdminService(queryRepo, roleRepo, microserviceRepo, notifier);
    }

    /**
     * La validación es private — la invocamos por reflexión
     * para no necesitar toda la cadena de dependencias que
     * {@code create} o {@code update} arrastran (entidad,
     * repositorios de roles, microservicios, etc.). Lo que
     * queremos verificar es la VALIDACIÓN de paramTypes,
     * aislado del resto.
     */
    private void invokeValidation(QueryRequest req) {
        try {
            var method = QueryAdminService.class.getDeclaredMethod(
                    "validateParamTypes", QueryRequest.class);
            method.setAccessible(true);
            method.invoke(service(), req);
        } catch (ReflectiveOperationException e) {
            if (e.getCause() instanceof RuntimeException re) throw re;
            if (e.getCause() instanceof Exception ex) throw new RuntimeException(ex);
            throw new RuntimeException(e);
        }
    }

    @Test
    void domainsAreNowInCuratedSoBoolSnPassesValidation() {
        assertThat(ParamTypes.CURATED).contains("BOOL_SN",
                "ESTADO_AI", "ESTADO_AC", "ESTADO_ACTIVO_INACTIVO",
                "NODO_CURRICULAR", "TITULACION_GRADO");
    }

    @Test
    void bodyRawXWithJsonbTypeIsAccepted() {
        QueryRequest req = new QueryRequest(
                null, "uuid-jb", "SELECT cast(:BODY_RAW.X as jsonb) FROM dual",
                "postgres", false, false, null, null, null,
                null, null, ExecutionMode.SELECT, null, null,
                params("BODY_RAW.X", "JSONB"));
        assertThatCode(() -> invokeValidation(req));
    }

    @Test
    void lowercaseKeysAreCanonicalizedInsteadOfRejected() {
        QueryRequest req = new QueryRequest(
                null, "uuid-lower",
                "SELECT * FROM users WHERE id = :BODY.ID",
                "postgres", false, false, null, null, null,
                null, null, ExecutionMode.SELECT, null, null,
                params("body.id", "BIGINT"));
        assertThatCode(() -> invokeValidation(req));
    }

    @Test
    void caseOnlyCollisionsInParamTypesAreRejected() {
        QueryRequest req = new QueryRequest(
                null, "uuid-dup", "SELECT 1",
                "postgres", false, false, null, null, null,
                null, null, ExecutionMode.SELECT, null, null,
                params("body.id", "BIGINT", "BODY.ID", "INTEGER"));
        assertThatThrownBy(() -> invokeValidation(req))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("difieren sólo por mayúsculas");
    }

    @Test
    void undeclaredCallerControlledPlaceholderIsRejected() {
        QueryRequest req = new QueryRequest(
                null, "uuid-missing",
                "SELECT * FROM users WHERE id = :BODY.ID",
                "postgres", false, false, null, null, null,
                null, null, ExecutionMode.SELECT, null, null,
                Map.of());
        assertThatThrownBy(() -> invokeValidation(req))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("BODY.ID")
                .hasMessageContaining("sin tipo declarado");
    }

    @Test
    void lowercasedCoveragePlaceholdersAlsoResolve() {
        QueryRequest req = new QueryRequest(
                null, "uuid-lc-cover",
                "SELECT * FROM users WHERE id = :body.id",
                "postgres", false, false, null, null, null,
                null, null, ExecutionMode.SELECT, null, null,
                params("BODY.ID", "BIGINT"));
        assertThatCode(() -> invokeValidation(req));
    }

    @Test
    void contextAndQueryPlaceholdersDoNotRequireTypes() {
        QueryRequest req = new QueryRequest(
                null, "uuid-sys",
                "SELECT * FROM users WHERE owner = :CONTEXT.USER_ID LIMIT :QUERY.SIZE",
                "postgres", false, false, null, null, null,
                null, null, ExecutionMode.SELECT, null, null,
                Map.of());
        assertThatCode(() -> invokeValidation(req));
    }

    @Test
    void invalidParamTypeValueIsRejected() {
        QueryRequest req = new QueryRequest(
                null, "uuid-badtype", "SELECT :BODY.X",
                "postgres", false, false, null, null, null,
                null, null, ExecutionMode.SELECT, null, null,
                params("BODY.X", "VARCHAR-99"));
        assertThatThrownBy(() -> invokeValidation(req))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("VARCHAR-99");
    }

    /**
     * V62 — el sufijo '!' marca el parámetro como obligatorio
     * (ver {@link ParamTypes#parseDeclaration}); el tipo base
     * ("BIGINT") sigue teniendo que estar en {@link ParamTypes#CURATED}.
     */
    @Test
    void requiredSuffixOnAValidTypeIsAccepted() {
        QueryRequest req = new QueryRequest(
                null, "uuid-required", "SELECT cast(:BODY.FK_GRADO as bigint)",
                "postgres", false, false, null, null, null,
                null, null, ExecutionMode.SELECT, null, null,
                params("BODY.FK_GRADO", "BIGINT!"));
        assertThatCode(() -> invokeValidation(req));
    }

    @Test
    void requiredSuffixOnAnArrayTypeIsAccepted() {
        QueryRequest req = new QueryRequest(
                null, "uuid-required-arr", "SELECT cast(:BODY.IDS as int8[])",
                "postgres", false, false, null, null, null,
                null, null, ExecutionMode.SELECT, null, null,
                params("BODY.IDS", "BIGINT[]!"));
        assertThatCode(() -> invokeValidation(req));
    }

    @Test
    void requiredSuffixDoesNotRescueAnInvalidBaseType() {
        QueryRequest req = new QueryRequest(
                null, "uuid-required-bad", "SELECT :BODY.X",
                "postgres", false, false, null, null, null,
                null, null, ExecutionMode.SELECT, null, null,
                params("BODY.X", "VARCHAR-99!"));
        assertThatThrownBy(() -> invokeValidation(req))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("VARCHAR-99!");
    }

    // ---------- V63: clasificación de archivos (FILE:clasificacion) ----------

    @Test
    void fileWithValidClassificationIsAccepted() {
        QueryRequest req = new QueryRequest(
                null, "uuid-file-clasificado", "SELECT cast(:BODY.FOTO as bigint)",
                "postgres", false, false, null, null, null,
                null, null, ExecutionMode.SELECT, null, null,
                params("BODY.FOTO", "FILE:perfilUsuario"));
        assertThatCode(() -> invokeValidation(req));
    }

    @Test
    void fileWithClassificationAndRequiredSuffixIsAccepted() {
        QueryRequest req = new QueryRequest(
                null, "uuid-file-clasificado-req", "SELECT cast(:BODY.FOTO as bigint)",
                "postgres", false, false, null, null, null,
                null, null, ExecutionMode.SELECT, null, null,
                params("BODY.FOTO", "FILE:perfilUsuario!"));
        assertThatCode(() -> invokeValidation(req));
    }

    @Test
    void fileWithInvalidClassificationFormatIsRejected() {
        QueryRequest req = new QueryRequest(
                null, "uuid-file-mal-clasificado", "SELECT cast(:BODY.FOTO as bigint)",
                "postgres", false, false, null, null, null,
                null, null, ExecutionMode.SELECT, null, null,
                params("BODY.FOTO", "FILE:con espacio"));
        assertThatThrownBy(() -> invokeValidation(req))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("clasificación de archivo inválida");
    }

    @Test
    void fileWithClassificationStartingWithDigitIsRejected() {
        QueryRequest req = new QueryRequest(
                null, "uuid-file-mal-clasificado-2", "SELECT cast(:BODY.FOTO as bigint)",
                "postgres", false, false, null, null, null,
                null, null, ExecutionMode.SELECT, null, null,
                params("BODY.FOTO", "FILE:1perfil"));
        assertThatThrownBy(() -> invokeValidation(req))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("clasificación de archivo inválida");
    }

    @Test
    void invalidParamKeyShapeIsRejected() {
        QueryRequest req = new QueryRequest(
                null, "uuid-badkey", "SELECT :BODY.X",
                "postgres", false, false, null, null, null,
                null, null, ExecutionMode.SELECT, null, null,
                params("BODY-X", "BIGINT"));
        assertThatThrownBy(() -> invokeValidation(req))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("BODY-X");
    }

    /* ====================== helpers ====================== */

    private static Map<String, String> params(String... kv) {
        Map<String, String> out = new LinkedHashMap<>();
        for (int i = 0; i + 1 < kv.length; i += 2) {
            out.put(kv[i], kv[i + 1]);
        }
        return out;
    }

    private static void assertThatCode(Runnable r) {
        try { r.run(); }
        catch (Throwable t) {
            org.assertj.core.api.Assertions.fail(
                    "Expected no throw but got: " + t.getClass().getSimpleName()
                    + ": " + t.getMessage());
        }
    }
}
