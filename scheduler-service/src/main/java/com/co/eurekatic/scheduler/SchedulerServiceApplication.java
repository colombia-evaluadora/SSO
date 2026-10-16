package com.co.eurekatic.scheduler;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.ConfigurationPropertiesScan;
import org.springframework.scheduling.annotation.EnableScheduling;

/**
 * Ejecutor de tareas repetitivas. Las tareas se declaran en configuracion
 * ({@code scheduler.tareas}); el servicio solo sabe disparar acciones
 * genericas ({@code sql}, {@code http}) y garantizar que cada disparo corre en
 * una sola replica.
 */
@SpringBootApplication(
        scanBasePackages = {"com.co.eurekatic.scheduler", "com.co.eurekatic.common.observability"})
@EnableScheduling
@ConfigurationPropertiesScan
public class SchedulerServiceApplication {

    public static void main(String[] args) {
        SpringApplication.run(SchedulerServiceApplication.class, args);
    }
}
