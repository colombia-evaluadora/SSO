package com.co.eurekatic.aicontrol.config;

import com.co.eurekatic.aicontrol.llm.ModeloInvoker;
import io.github.resilience4j.bulkhead.Bulkhead;
import io.github.resilience4j.bulkhead.BulkheadConfig;
import io.github.resilience4j.circuitbreaker.CircuitBreaker;
import io.github.resilience4j.circuitbreaker.CircuitBreakerConfig;
import io.github.resilience4j.ratelimiter.RateLimiter;
import io.github.resilience4j.ratelimiter.RateLimiterConfig;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Primary;
import org.springframework.web.server.ResponseStatusException;

import java.time.Duration;

/**
 * Protecciones alrededor del modelo, construidas a mano (sin starter) igual
 * que en query-service y notification-service.
 *
 * <ul>
 *   <li><b>RateLimiter</b>: el plan gratuito de NVIDIA ronda las 40
 *       peticiones por minuto; pasarse devuelve 429 del proveedor. Frenar
 *       antes, aca, da un 429 propio con {@code Retry-After}.</li>
 *   <li><b>Bulkhead</b>: una generacion tarda segundos; sin tope, un pico
 *       deja todos los hilos esperando al proveedor.</li>
 *   <li><b>CircuitBreaker</b>: si el proveedor esta caido se responde 503 al
 *       instante en vez de esperar el timeout en cada request.</li>
 * </ul>
 *
 * <p>Los reintentos los hace el SDK de OpenAI ({@code spring.ai.openai.max-retries});
 * por eso aca no hay Retry: apilarlos multiplicaria las llamadas.
 */
@Configuration
public class ResilienceConfig {

    private static final int VENTANA_CIRCUITO = 10;
    private static final int LLAMADAS_MINIMAS_CIRCUITO = 5;

    @Bean
    public RateLimiter modeloRateLimiter(AiProperties props) {
        return RateLimiter.of("modelo", RateLimiterConfig.custom()
                .limitForPeriod(props.rateLimitPerMin())
                .limitRefreshPeriod(Duration.ofMinutes(1))
                .timeoutDuration(props.rateLimitTimeout())
                .build());
    }

    @Bean
    @Primary
    public Bulkhead modeloBulkhead(AiProperties props) {
        return Bulkhead.of("modelo", BulkheadConfig.custom()
                .maxConcurrentCalls(props.maxConcurrent())
                .maxWaitDuration(props.rateLimitTimeout())
                .build());
    }

    /**
     * Bulkhead del razonador. Sus llamadas son largas (planea y encadena
     * herramientas); con su propio tope no ocupan los hilos del resto. Sin
     * espera: si esta lleno, el turno responde 429 en vez de encolarse.
     */
    @Bean
    public Bulkhead razonadorBulkhead(AgenteProperties props) {
        return Bulkhead.of("razonador", BulkheadConfig.custom()
                .maxConcurrentCalls(props.limites().maxConcurrentRazonador())
                .maxWaitDuration(Duration.ZERO)
                .build());
    }

    /**
     * Invocador del razonador. Comparte el cupo por minuto y el circuito con
     * el modelo rapido porque es la misma cuenta del proveedor.
     */
    @Bean
    @Qualifier("razonador")
    public ModeloInvoker modeloInvokerRazonador(RateLimiter modeloRateLimiter,
                                                @Qualifier("razonadorBulkhead") Bulkhead razonadorBulkhead,
                                                CircuitBreaker modeloCircuitBreaker) {
        return new ModeloInvoker(modeloRateLimiter, razonadorBulkhead, modeloCircuitBreaker);
    }

    @Bean
    public CircuitBreaker modeloCircuitBreaker(AiProperties props) {
        return CircuitBreaker.of("modelo", CircuitBreakerConfig.custom()
                .failureRateThreshold(props.circuitFailureRate())
                .slidingWindowSize(VENTANA_CIRCUITO)
                .minimumNumberOfCalls(LLAMADAS_MINIMAS_CIRCUITO)
                .waitDurationInOpenState(props.circuitOpenWait())
                // Un 4xx nuestro (JSON invalido del modelo, 429 propio) no es
                // una caida del proveedor y no debe abrir el circuito.
                .ignoreExceptions(ResponseStatusException.class)
                .build());
    }
}
