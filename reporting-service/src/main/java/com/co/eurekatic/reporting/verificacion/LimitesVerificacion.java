package com.co.eurekatic.reporting.verificacion;

import com.co.eurekatic.reporting.config.ReportingProperties;
import com.github.benmanes.caffeine.cache.Cache;
import com.github.benmanes.caffeine.cache.Caffeine;
import com.github.benmanes.caffeine.cache.Ticker;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;
import org.springframework.web.server.ResponseStatusException;

import java.time.Duration;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Frenos de la verificacion publica: peticiones por IP y minuto, e intentos
 * fallidos del segundo factor por codigo (5 en 15 minutos, despues 429 hasta
 * que vence la ventana).
 *
 * <p>Ventana fija desde el primer evento: el contador se crea con la entrada
 * y {@code expireAfterWrite} no se renueva al incrementarlo. En memoria y por
 * instancia, a proposito: con N instancias el limite efectivo es N veces el
 * configurado, que sigue dejando 4 digitos (10.000 combinaciones) fuera de
 * alcance de un ataque por fuerza bruta en la vida util de un boletin.
 */
@Component
public class LimitesVerificacion {

    private final int porIpMinuto;
    private final int intentosMax;
    private final Duration ventanaIntentos;
    private final Cache<String, AtomicInteger> porIp;
    private final Cache<String, AtomicInteger> fallos;

    @Autowired
    public LimitesVerificacion(ReportingProperties props) {
        this(props.getVerificacion(), Ticker.systemTicker());
    }

    LimitesVerificacion(ReportingProperties.Verificacion v, Ticker ticker) {
        this.porIpMinuto = Math.max(1, v.getLimitePorIpMinuto());
        this.intentosMax = Math.max(1, v.getIntentosFallidosMax());
        this.ventanaIntentos = v.getVentanaIntentos();
        this.porIp = Caffeine.newBuilder().ticker(ticker)
                .expireAfterWrite(Duration.ofMinutes(1)).maximumSize(100_000).build();
        this.fallos = Caffeine.newBuilder().ticker(ticker)
                .expireAfterWrite(ventanaIntentos).maximumSize(100_000).build();
    }

    /** 429 si la IP ya hizo su cupo de peticiones del minuto. */
    public void contarPeticion(String ip) {
        String clave = ip == null || ip.isBlank() ? "desconocida" : ip;
        int n = porIp.get(clave, k -> new AtomicInteger()).incrementAndGet();
        if (n > porIpMinuto) {
            throw new Limitado("Demasiadas consultas. Intenta de nuevo en un minuto.", 60);
        }
    }

    /** 429 si el codigo agoto sus intentos del segundo factor. */
    public void exigirIntentosDisponibles(String codigo) {
        AtomicInteger n = fallos.getIfPresent(codigo);
        if (n != null && n.get() >= intentosMax) {
            throw new Limitado("Se superaron los intentos permitidos para este boletin. "
                    + "Intenta de nuevo mas tarde.", ventanaIntentos.toSeconds());
        }
    }

    public void registrarFallo(String codigo) {
        fallos.get(codigo, k -> new AtomicInteger()).incrementAndGet();
    }

    public void limpiarFallos(String codigo) {
        fallos.invalidate(codigo);
    }

    /** 429 con Retry-After. */
    static final class Limitado extends ResponseStatusException {
        private final long reintentarEn;

        Limitado(String mensaje, long reintentarEn) {
            super(HttpStatus.TOO_MANY_REQUESTS, mensaje);
            this.reintentarEn = reintentarEn;
        }

        @Override
        public HttpHeaders getHeaders() {
            HttpHeaders h = new HttpHeaders();
            h.set(HttpHeaders.RETRY_AFTER, String.valueOf(reintentarEn));
            return h;
        }
    }
}
