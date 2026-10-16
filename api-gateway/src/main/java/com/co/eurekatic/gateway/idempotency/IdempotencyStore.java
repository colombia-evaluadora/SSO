package com.co.eurekatic.gateway.idempotency;

import reactor.core.publisher.Mono;

import java.time.Duration;

/**
 * Almacén de claves {@code Idempotency-Key} (BE-1, escritura offline). Las
 * claves llegan ya particionadas por usuario ({@code sub}). Separado de Redis
 * para probar el filtro sin un servidor.
 */
public interface IdempotencyStore {

    /** Reserva la clave como en curso; {@code false} si ya existía. */
    Mono<Boolean> reserve(String key, StoredResponse pending, Duration ttl);

    /** Lo guardado para la clave, o vacío. */
    Mono<StoredResponse> get(String key);

    /** Guarda la respuesta definitiva para repetirla en los reintentos. */
    Mono<Void> complete(String key, StoredResponse done, Duration ttl);

    /** Libera la clave (5xx o error): el reintento vuelve a ejecutarse. */
    Mono<Void> release(String key);
}
