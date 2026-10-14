package com.co.eurekatic.aicontrol.config.agente;

import org.springframework.context.annotation.Configuration;
import org.springframework.scheduling.annotation.EnableScheduling;

/**
 * Activa las tareas programadas del agente: hoy, el refresco del catalogo de herramientas.
 */
@Configuration
@EnableScheduling
public class PlanificacionConfig {
}
