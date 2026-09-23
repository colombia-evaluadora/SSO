package com.co.eurekatic.aicontrol.config;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.boot.context.properties.bind.DefaultValue;

import java.time.Duration;

/**
 * Calibracion del servicio que no es del proveedor. Lo del proveedor
 * (base-url, api-key, modelo, temperatura, max-tokens...) vive en
 * {@code spring.ai.openai.*}.
 *
 * @param queryServiceBaseUrl instancia de query-service del catalogo eval-col
 * @param requestTimeout      tope de cada llamada al query-service
 * @param extraBodyJson       campos que el proveedor acepta fuera del estandar
 *                            OpenAI, como JSON. Va como JSON y no como mapa
 *                            en el yml para que los booleanos lleguen como
 *                            booleanos: un placeholder de Spring los
 *                            convertiria en el string "false", que una
 *                            plantilla Jinja evalua como verdadero
 * @param maxPalabras         extension objetivo del resumen
 * @param promptVersion       entra en la clave de cache: subirla invalida
 *                            todo lo generado con los prompts anteriores
 * @param cacheTtl            vida de un resumen en Redis; 0 desactiva la cache
 * @param rateLimitPerMin     tope global de llamadas al modelo por minuto
 * @param rateLimitTimeout    cuanto espera un request por un permiso antes
 *                            de responder 429
 * @param maxConcurrent       llamadas simultaneas al modelo por instancia
 * @param circuitFailureRate  porcentaje de fallos que abre el circuito
 * @param circuitOpenWait     cuanto queda abierto antes de volver a probar
 */
@ConfigurationProperties("sso.ai")
public record AiProperties(
        String queryServiceBaseUrl,
        @DefaultValue("30s") Duration requestTimeout,
        @DefaultValue("") String extraBodyJson,
        @DefaultValue("250") int maxPalabras,
        @DefaultValue("v1") String promptVersion,
        @DefaultValue("7d") Duration cacheTtl,
        @DefaultValue("35") int rateLimitPerMin,
        @DefaultValue("20s") Duration rateLimitTimeout,
        @DefaultValue("4") int maxConcurrent,
        @DefaultValue("50") float circuitFailureRate,
        @DefaultValue("60s") Duration circuitOpenWait) {
}
