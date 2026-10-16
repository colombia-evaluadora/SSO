package com.co.eurekatic.notificationservice.config;

import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.output.ValidateOutput;
import org.flywaydb.core.api.output.ValidateResult;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.flyway.autoconfigure.FlywayMigrationStrategy;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.io.Resource;
import org.springframework.core.io.support.PathMatchingResourcePatternResolver;

import javax.sql.DataSource;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.List;

/**
 * Misma regla que el deploy de {@code postgres/migrations}
 * ({@code scripts/flyway-deploy.sh}): una migracion ya aplicada se EDITA en
 * lugar de crear otra que altere su objeto, y al arrancar se re-ejecuta.
 *
 * <p>Sin esto, editar {@code V1__init.sql} (p. ej. el CHECK de
 * {@code provider_config.impl}) haria fallar el {@code validate} de Flyway en
 * toda base ya migrada y el servicio no arrancaria. Pasos: detectar las
 * versiones con checksum distinto, re-ejecutar su SQL en una sola transaccion
 * (las migraciones de este servicio son idempotentes), {@code repair} para
 * realinear el historial y {@code migrate} para las pendientes.
 */
@Configuration
public class FlywayReaplicacionConfig {

    private static final Logger log = LoggerFactory.getLogger(FlywayReaplicacionConfig.class);

    @Bean
    FlywayMigrationStrategy reaplicaMigracionesEditadas(DataSource dataSource) {
        return flyway -> {
            List<String> editadas = versionesEditadas(flyway);
            if (!editadas.isEmpty()) {
                log.warn("Migraciones editadas tras aplicarse, se re-ejecutan: {}", editadas);
                reaplicar(dataSource, flyway, editadas);
                flyway.repair();
            }
            flyway.migrate();
        };
    }

    static List<String> versionesEditadas(Flyway flyway) {
        ValidateResult result;
        try {
            result = flyway.validateWithResult();
        } catch (RuntimeException ex) {
            // Base sin historial todavia (primer arranque): nada que re-aplicar.
            log.debug("validate previo al migrate fallo: {}", ex.getMessage());
            return List.of();
        }
        List<String> versiones = new ArrayList<>();
        if (result == null || result.invalidMigrations == null) return versiones;
        for (ValidateOutput out : result.invalidMigrations) {
            if (out.version == null || out.errorDetails == null) continue;
            if ("CHECKSUM_MISMATCH".equals(String.valueOf(out.errorDetails.errorCode))) {
                versiones.add(out.version);
            }
        }
        return versiones;
    }

    private static void reaplicar(DataSource dataSource, Flyway flyway, List<String> versiones) {
        var resolver = new PathMatchingResourcePatternResolver();
        String[] locations = flyway.getConfiguration().getLocations().length == 0
                ? new String[] {"classpath:db/migration"}
                : java.util.Arrays.stream(flyway.getConfiguration().getLocations())
                        .map(Object::toString).toArray(String[]::new);
        try (Connection conn = dataSource.getConnection()) {
            boolean autoCommit = conn.getAutoCommit();
            conn.setAutoCommit(false);
            try (Statement st = conn.createStatement()) {
                for (String version : versiones) {
                    st.execute(leerScript(resolver, locations, version));
                }
                conn.commit();
            } catch (SQLException | RuntimeException ex) {
                conn.rollback();
                throw new IllegalStateException(
                        "No se pudieron re-aplicar las migraciones editadas " + versiones, ex);
            } finally {
                conn.setAutoCommit(autoCommit);
            }
        } catch (SQLException ex) {
            throw new IllegalStateException("Sin conexion para re-aplicar migraciones", ex);
        }
    }

    private static String leerScript(PathMatchingResourcePatternResolver resolver,
                                     String[] locations, String version) {
        for (String location : locations) {
            String base = location.startsWith("classpath:")
                    ? "classpath*:" + location.substring("classpath:".length())
                    : location;
            try {
                Resource[] found = resolver.getResources(base + "/V" + version + "__*.sql");
                if (found.length > 0) {
                    return new String(found[0].getInputStream().readAllBytes(), StandardCharsets.UTF_8);
                }
            } catch (IOException ex) {
                throw new IllegalStateException("No se pudo leer V" + version, ex);
            }
        }
        throw new IllegalStateException("No existe el fichero de la migracion V" + version);
    }
}
