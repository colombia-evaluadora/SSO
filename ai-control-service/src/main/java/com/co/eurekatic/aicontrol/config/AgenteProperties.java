package com.co.eurekatic.aicontrol.config;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.boot.context.properties.bind.DefaultValue;

import java.time.Duration;

/**
 * Calibracion del agente conversacional: modelos, presupuestos de herramientas,
 * memoria y limites. Lo comun al proveedor (base-url, api-key) sigue en
 * {@code spring.ai.openai.*}.
 *
 * @param modeloRapido           modelo de clasificacion y redaccion, sin razonamiento
 * @param modeloRazonador        modelo que planea y elige herramientas
 * @param extraBodyRapidoJson    campos extra del proveedor para el modelo rapido, como JSON
 * @param extraBodyRazonadorJson campos extra del proveedor para el razonador, como JSON
 * @param maxTokensRapido        tope de tokens de salida del modelo rapido
 * @param maxTokensRazonador     tope de tokens del razonador; cuenta tambien el razonamiento
 * @param maxTotalToolCalls      llamadas a herramientas por turno, en total
 * @param maxCallsPorHerramienta llamadas a una misma herramienta por turno
 * @param memoriaMaxMensajes     mensajes de la conversacion que ve el modelo
 * @param memoriaTtl             vida de la memoria en Redis desde la ultima escritura
 * @param accionExpira           cuanto espera una accion de escritura su confirmacion
 * @param rateLimitUsuarioPorMin turnos por minuto y por usuario
 * @param textoMaxCaracteres     longitud maxima de un mensaje del usuario
 * @param maxConcurrentRazonador llamadas simultaneas al razonador por instancia
 */
@ConfigurationProperties("sso.ai.agente")
public record AgenteProperties(
        @DefaultValue("MiniMax-M3") String modeloRapido,
        @DefaultValue("MiniMax-M3") String modeloRazonador,
        @DefaultValue("{\"thinking\":{\"type\":\"disabled\"}}") String extraBodyRapidoJson,
        @DefaultValue("{\"thinking\":{\"type\":\"adaptive\"},\"reasoning_split\":true}") String extraBodyRazonadorJson,
        @DefaultValue("1500") int maxTokensRapido,
        @DefaultValue("6000") int maxTokensRazonador,
        @DefaultValue("15") int maxTotalToolCalls,
        @DefaultValue("5") int maxCallsPorHerramienta,
        @DefaultValue("30") int memoriaMaxMensajes,
        @DefaultValue("24h") Duration memoriaTtl,
        @DefaultValue("10m") Duration accionExpira,
        @DefaultValue("20") int rateLimitUsuarioPorMin,
        @DefaultValue("4000") int textoMaxCaracteres,
        @DefaultValue("2") int maxConcurrentRazonador) {
}
