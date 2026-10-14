package com.co.eurekatic.aicontrol.agente.ui.registro;

import com.co.eurekatic.aicontrol.agente.comun.PoliticaRefresco;
import com.co.eurekatic.aicontrol.config.agente.AgenteProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Mantiene en memoria el registro de pantallas y formularios. Mismo ciclo que el catalogo de
 * herramientas: arranca vacio sin bloquear, reintenta mientras este vacio y refresca cada intervalo.
 * Un fallo conserva el registro anterior.
 */
@Component
public class RegistroUiLoader {

    private static final Logger log = LoggerFactory.getLogger(RegistroUiLoader.class);

    private final RegistroUiRepository repositorio;
    private final Duration refresco;
    private final Clock reloj;
    private final AtomicReference<RegistroUi> actual = new AtomicReference<>(RegistroUi.vacio());
    private final AtomicReference<Instant> ultimaCarga = new AtomicReference<>(Instant.EPOCH);

    @Autowired
    public RegistroUiLoader(RegistroUiRepository repositorio, AgenteProperties props) {
        this(repositorio, props.catalogo().refresco(), Clock.systemUTC());
    }

    RegistroUiLoader(RegistroUiRepository repositorio, Duration refresco, Clock reloj) {
        this.repositorio = repositorio;
        this.refresco = refresco;
        this.reloj = reloj;
    }

    /** Registro vigente; nunca null. */
    public RegistroUi registro() {
        return actual.get();
    }

    public synchronized void refrescar() {
        try {
            RegistroUi nuevo = RegistroUi.con(repositorio.pantallas(), repositorio.formularios());
            actual.set(nuevo);
            ultimaCarga.set(reloj.instant());
            log.info("Registro de UI del agente: {} pantallas", nuevo.pantallasCargadas());
        } catch (RuntimeException e) {
            log.warn("No se pudo cargar el registro de UI ({}); se conserva el anterior", e.getClass().getSimpleName());
        }
    }

    @Scheduled(fixedDelayString = "${sso.ai.agente.catalogo.reintento:PT30S}", initialDelayString = "PT0S")
    public void ciclo() {
        if (PoliticaRefresco.toca(actual.get().estaVacio(), ultimaCarga.get(), reloj.instant(), refresco)) {
            refrescar();
        }
    }
}
