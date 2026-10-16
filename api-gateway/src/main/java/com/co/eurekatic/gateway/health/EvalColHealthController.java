package com.co.eurekatic.gateway.health;

import org.springframework.http.CacheControl;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import reactor.core.publisher.Mono;

import java.util.Map;

/**
 * {@code GET /api/eval-col/health}: latido del front de Colombia Evaluadora
 * para distinguir "servidor alcanzable" de "sin red / portal cautivo".
 *
 * <p>Vive en el gateway y no en query-service a proposito: los controladores
 * WebFlux ({@code RequestMappingHandlerMapping}, orden 0) se resuelven antes
 * que las rutas del gateway ({@code RoutePredicateHandlerMapping}, orden 1),
 * asi que esta ruta concreta gana a {@code /api/eval-col/**} sin tocar el
 * catalogo de rutas ni recrear instancias de query-service. Ademas responde
 * aunque query-service este caido, que es lo que el latido quiere medir: si
 * el borde contesta, hay red; los errores de servicio los reporta cada
 * peticion real.
 *
 * <p>Sin autenticacion (ver {@code GatewaySecurityConfig}), sin base de
 * datos y sin informacion interna: solo un estado fijo y la hora del
 * servidor. JSON para que la pagina HTML de un portal cautivo no pase por
 * respuesta valida; {@code no-store} para que ningun cache intermedio
 * conteste por el servidor.
 */
@RestController
public class EvalColHealthController {

    @GetMapping(value = "/api/eval-col/health", produces = MediaType.APPLICATION_JSON_VALUE)
    public Mono<ResponseEntity<Map<String, Object>>> health() {
        return Mono.just(ResponseEntity.ok()
                .cacheControl(CacheControl.noStore())
                .body(Map.of("status", "ok", "ts", System.currentTimeMillis())));
    }
}
