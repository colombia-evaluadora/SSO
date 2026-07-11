package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.ssoadmin.dto.MicroserviceTestConnectionRequest;
import com.co.eurekatic.ssoadmin.dto.MicroserviceTestConnectionResponse;
import org.junit.jupiter.api.Disabled;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * Cobertura mínima de {@link MicroserviceService#testConnection}.
 *
 * <p>La parte interesante — abrir una conexión real contra un driver
 * JDBC — no se mockea con Mockito porque {@link java.sql.DriverManager}
 * es estático. La verificación de esa ruta se hace con curl contra el
 * stack en compose (ver {@code plans/typed-nibbling-twilight.md} §
 * "Verification / Backend"). El caso {@code @Disabled} abajo ancla ese
 * flujo manual y documenta qué probar.
 *
 * <p>Lo que sí cubrimos aquí: la validación previa (jdbcUrl sin prefijo
 * {@code jdbc:}), porque es la única decisión lógica que no depende del
 * driver. El resto de ramas son básicamente try-with-resources +
 * propagación del mensaje del driver.
 */
class MicroserviceServiceTestConnectionTest {

    private final MicroserviceService service =
            new MicroserviceService(null, null, null, null);

    @Test
    void rejectsJdbcUrlWithoutPrefix() {
        var req = new MicroserviceTestConnectionRequest(
                "not-a-jdbc-url", "user", "pw", "postgres");
        assertThatThrownBy(() -> service.testConnection(req))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("jdbc:");
    }

    @Test
    void rejectsNullJdbcUrl() {
        var req = new MicroserviceTestConnectionRequest(
                null, "user", "pw", "postgres");
        assertThatThrownBy(() -> service.testConnection(req))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("jdbc:");
    }

    /**
     * Cubre los caminos que tocan el driver (éxito, fallo de auth,
     * host inexistente, timeout). Marcado como {@code @Disabled}
     * porque la lógica no se puede mockear con Mockito (DriverManager
     * es estático) y un test con Testcontainers excede el valor del
     * código bajo prueba.
     *
     * <p>Verificación manual: arrancar el stack en compose y ejecutar
     * los 4 curl del plan (éxito contra Postgres, fallo URL malformada,
     * fallo host inexistente, 401 sin token).
     */
    @Test
    @Disabled("Manual: ver plan §Verification/Backend — DriverManager es estático, no se mockea")
    void driverPaths_requireManualVerification() {
        var req = new MicroserviceTestConnectionRequest(
                "jdbc:postgresql://sso-postgres:5432/sso",
                "sso",
                "change-me",
                "postgres");
        MicroserviceTestConnectionResponse resp = service.testConnection(req);
        assertThat(resp.ok()).isTrue();
        assertThat(resp.latencyMs()).isGreaterThan(0);
    }
}