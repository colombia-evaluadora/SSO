package com.co.eurekatic.aicontrol.agente.catalogo.carga;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.CatalogoHerramientas;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.config.agente.AgenteProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Mantiene el catalogo de herramientas en memoria. Arranca sin bloquear el servicio: si la
 * base no responde, el catalogo queda vacio, se avisa en WARN y se reintenta cada
 * {@code reintento}. Con el catalogo cargado se relee cada {@code refresco}.
 *
 * <p>Sin Redis pub/sub en esta fase: los cambios en {@code ai.herramienta} se ven al
 * siguiente refresco. Un fallo al releer conserva el catalogo anterior.
 */
@Component
public class CatalogoHerramientasLoader {

    private static final Logger log = LoggerFactory.getLogger(CatalogoHerramientasLoader.class);

    private final CatalogoRepository repositorio;
    private final MapeadorHerramienta mapeador;
    private final TechoHerramientas techo;
    private final AgenteProperties.Catalogo props;
    private final Clock reloj;
    private final AtomicReference<CatalogoHerramientas> actual =
            new AtomicReference<>(CatalogoHerramientas.vacio());
    private final AtomicReference<Instant> ultimaCarga = new AtomicReference<>(Instant.EPOCH);

    @Autowired
    public CatalogoHerramientasLoader(CatalogoRepository repositorio, AgenteProperties props) {
        this(repositorio, new MapeadorHerramienta(), new TechoHerramientas(), props.catalogo(), Clock.systemUTC());
    }

    CatalogoHerramientasLoader(CatalogoRepository repositorio, MapeadorHerramienta mapeador,
                               TechoHerramientas techo, AgenteProperties.Catalogo props, Clock reloj) {
        this.repositorio = repositorio;
        this.mapeador = mapeador;
        this.techo = techo;
        this.props = props;
        this.reloj = reloj;
    }

    /** Catalogo vigente. Nunca es null: al arrancar, y si la base falla, es vacio. */
    public CatalogoHerramientas catalogo() {
        return actual.get();
    }

    /**
     * Relee la base y reemplaza el catalogo. Un fallo deja el catalogo anterior y un WARN
     * sin datos: el mensaje solo lleva el tipo de error.
     */
    public synchronized void refrescar() {
        try {
            List<HerramientaDef> cargadas = cargar(repositorio.leerActivas());
            actual.set(CatalogoHerramientas.con(cargadas));
            ultimaCarga.set(reloj.instant());
            log.info("Catalogo de herramientas del agente: {} activas", cargadas.size());
        } catch (RuntimeException e) {
            log.warn("No se pudo cargar el catalogo de herramientas ({}); se conserva el anterior de {} herramientas",
                    e.getClass().getSimpleName(), actual.get().tamano());
        }
    }

    /** Disparo periodico: arranque, reintento con el catalogo vacio y refresco normal. */
    @Scheduled(fixedDelayString = "${sso.ai.agente.catalogo.reintento:PT30S}", initialDelayString = "PT0S")
    public void ciclo() {
        if (debeRefrescar(actual.get().estaVacio(), ultimaCarga.get(), reloj.instant(), props.refresco())) {
            refrescar();
        }
    }

    static boolean debeRefrescar(boolean vacio, Instant ultima, Instant ahora, Duration refresco) {
        return vacio || !ahora.isBefore(ultima.plus(refresco));
    }

    /** Mapea y aplica el techo. Una fila que no se puede interpretar o que el techo rechaza se descarta sola. */
    private List<HerramientaDef> cargar(List<FilaCatalogo> filas) {
        List<HerramientaDef> aceptadas = new ArrayList<>();
        for (FilaCatalogo fila : filas) {
            try {
                HerramientaDef herramienta = mapeador.mapear(fila);
                techo.motivoRechazo(herramienta).ifPresentOrElse(
                        motivo -> log.warn("Herramienta {} descartada por el techo: {}", fila.codigo(), motivo),
                        () -> aceptadas.add(herramienta));
            } catch (RuntimeException e) {
                log.warn("Herramienta {} descartada: {}", fila.codigo(), e.getMessage());
            }
        }
        return List.copyOf(aceptadas);
    }
}
