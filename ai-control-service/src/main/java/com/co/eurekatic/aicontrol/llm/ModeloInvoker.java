package com.co.eurekatic.aicontrol.llm;

import io.github.resilience4j.bulkhead.Bulkhead;
import io.github.resilience4j.bulkhead.BulkheadFullException;
import io.github.resilience4j.circuitbreaker.CallNotPermittedException;
import io.github.resilience4j.circuitbreaker.CircuitBreaker;
import io.github.resilience4j.ratelimiter.RateLimiter;
import io.github.resilience4j.ratelimiter.RequestNotPermitted;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;
import org.springframework.web.server.ResponseStatusException;

import java.util.function.Supplier;

/**
 * Ejecuta una llamada al modelo detras del rate limiter, el bulkhead y el
 * circuit breaker, y traduce cada rechazo a un status HTTP que el front
 * pueda mostrar.
 */
@Component
public class ModeloInvoker {

    private static final Logger log = LoggerFactory.getLogger(ModeloInvoker.class);

    private final RateLimiter rateLimiter;
    private final Bulkhead bulkhead;
    private final CircuitBreaker circuitBreaker;

    public ModeloInvoker(RateLimiter rateLimiter, Bulkhead bulkhead, CircuitBreaker circuitBreaker) {
        this.rateLimiter = rateLimiter;
        this.bulkhead = bulkhead;
        this.circuitBreaker = circuitBreaker;
    }

    public <T> T invocar(Supplier<T> llamada) {
        // Orden: primero el cupo por minuto (no ocupa hilo del bulkhead
        // esperando), luego la concurrencia, y el circuito envuelve solo la
        // llamada real para contar unicamente fallos del proveedor.
        Supplier<T> decorada = RateLimiter.decorateSupplier(rateLimiter,
                Bulkhead.decorateSupplier(bulkhead,
                        CircuitBreaker.decorateSupplier(circuitBreaker, llamada)));
        try {
            return decorada.get();
        } catch (RequestNotPermitted | BulkheadFullException e) {
            throw new ResponseStatusException(HttpStatus.TOO_MANY_REQUESTS,
                    "El servicio de IA está atendiendo demasiadas solicitudes. Intente de nuevo en un minuto.") {
                @Override
                public HttpHeaders getHeaders() {
                    HttpHeaders h = new HttpHeaders();
                    h.set(HttpHeaders.RETRY_AFTER, "60");
                    return h;
                }
            };
        } catch (CallNotPermittedException e) {
            throw new ResponseStatusException(HttpStatus.SERVICE_UNAVAILABLE,
                    "El proveedor de IA no está respondiendo. Intente más tarde.");
        } catch (ResponseStatusException e) {
            throw e;
        } catch (RuntimeException e) {
            log.error("Fallo la llamada al modelo: {}", e.toString());
            throw new ResponseStatusException(HttpStatus.BAD_GATEWAY,
                    "El proveedor de IA devolvió un error. Intente de nuevo.");
        }
    }
}
