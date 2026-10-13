package com.co.eurekatic.aicontrol.agente.catalogo.turno;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Cache en memoria de los menus por clave (hash del token), con expiracion simple. Sin
 * dependencias: una entrada vence a los {@code ttl} y se purga al llenarse. Los menus de un
 * usuario cambian poco; un minuto de retraso es aceptable y el gate sigue siendo la base.
 */
final class CacheMenus {

    static final int MAX_ENTRADAS = 5_000;

    private record Entrada(Map<String, AccesoMenu> menus, Instant expira) {
    }

    private final ConcurrentHashMap<String, Entrada> entradas = new ConcurrentHashMap<>();
    private final Duration ttl;
    private final Clock reloj;

    CacheMenus(Duration ttl, Clock reloj) {
        this.ttl = ttl;
        this.reloj = reloj;
    }

    Optional<Map<String, AccesoMenu>> obtener(String clave) {
        Entrada entrada = entradas.get(clave);
        if (entrada == null) {
            return Optional.empty();
        }
        if (!reloj.instant().isBefore(entrada.expira())) {
            entradas.remove(clave, entrada);
            return Optional.empty();
        }
        return Optional.of(entrada.menus());
    }

    void poner(String clave, Map<String, AccesoMenu> menus) {
        if (entradas.size() >= MAX_ENTRADAS) {
            purgar();
        }
        entradas.put(clave, new Entrada(menus, reloj.instant().plus(ttl)));
    }

    private void purgar() {
        Instant ahora = reloj.instant();
        entradas.entrySet().removeIf(e -> !ahora.isBefore(e.getValue().expira()));
    }
}
