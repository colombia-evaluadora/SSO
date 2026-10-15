package com.co.eurekatic.scheduler.config;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.PositiveOrZero;
import java.time.Duration;
import java.time.ZoneId;
import java.util.List;
import java.util.Map;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.boot.context.properties.bind.DefaultValue;
import org.springframework.validation.annotation.Validated;

/**
 * Catalogo de tareas. Vive en configuracion (application.yml o un fichero
 * montado con {@code spring.config.import}) para que agregar una tarea no
 * exija tocar codigo ni la base.
 *
 * @param tablaBloqueo tabla de ShedLock, calificada con su esquema
 * @param zona         zona horaria por defecto de los cron
 * @param tareas       tareas declaradas
 */
@Validated
@ConfigurationProperties("scheduler")
public record SchedulerProperties(
        @NotBlank @DefaultValue("scheduler.shedlock") String tablaBloqueo,
        @NotNull @DefaultValue("America/Bogota") ZoneId zona,
        @DefaultValue List<@Valid Tarea> tareas) {

    /**
     * Una tarea: cuando ({@code cron} o {@code cada}, exactamente uno), que
     * accion ejecuta y con que parametros.
     *
     * @param bloqueoMaximo tope del bloqueo si la replica muere a mitad de la
     *                      ejecucion; debe superar la duracion esperada
     * @param bloqueoMinimo tiempo que el bloqueo se mantiene aunque la tarea
     *                      acabe antes, para que una replica con el reloj
     *                      algo atrasado no repita el mismo disparo
     */
    public record Tarea(
            @NotBlank @Pattern(regexp = "[a-z0-9][a-z0-9-]{0,62}") String id,
            String cron,
            Duration cada,
            ZoneId zona,
            @DefaultValue("true") boolean activa,
            @NotBlank String accion,
            @DefaultValue Map<String, Object> parametros,
            @NotNull @DefaultValue("PT10M") Duration bloqueoMaximo,
            @NotNull @DefaultValue("PT5S") Duration bloqueoMinimo,
            @PositiveOrZero @DefaultValue("0") int reintentos,
            @NotNull @DefaultValue("PT30S") Duration esperaReintento) {
    }
}
