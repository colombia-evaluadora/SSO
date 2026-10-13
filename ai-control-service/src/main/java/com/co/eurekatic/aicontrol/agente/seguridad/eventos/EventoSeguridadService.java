package com.co.eurekatic.aicontrol.agente.seguridad.eventos;

import com.co.eurekatic.aicontrol.agente.comun.Huellas;
import com.co.eurekatic.aicontrol.agente.persistencia.seguridad.EventoSeguridadStore;
import com.co.eurekatic.aicontrol.agente.persistencia.seguridad.EventoSeguridadStore.NuevoEvento;
import com.co.eurekatic.aicontrol.agente.seguridad.Hallazgo;
import com.co.eurekatic.aicontrol.agente.seguridad.Motivo;
import io.micrometer.core.instrument.MeterRegistry;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import java.util.Objects;
import java.util.Optional;
import java.util.UUID;

/**
 * Registro de bloqueos y descartes del agente: {@code ai.evento_seguridad} y la
 * metrica {@code ai.firewall.bloqueos{capa,motivo}}.
 *
 * <p>Nunca guarda el texto, solo su huella SHA-256. El motivo es un
 * {@link Motivo} validado, asi que no hay texto libre que pueda llegar a la
 * metrica.
 *
 * <p>La metrica se cuenta antes de escribir en la base: si la base falla, el
 * bloqueo sigue contado y el turno no se tumba.
 */
@Service
public class EventoSeguridadService {

    private static final Logger log = LoggerFactory.getLogger(EventoSeguridadService.class);
    static final String METRICA = "ai.firewall.bloqueos";

    /**
     * Un evento a registrar.
     *
     * @param conversacionId   conversacion donde ocurrio; vacio si fue antes de crearla
     * @param fkUsuario        usuario dueno de la entrada
     * @param hallazgo         lo que se detecto: filtro, riesgo y motivo
     * @param textoNormalizado texto que se audita; solo se guarda su huella
     */
    public record RegistroEvento(Optional<UUID> conversacionId, long fkUsuario, Hallazgo hallazgo,
                                 Optional<String> textoNormalizado) {

        public RegistroEvento {
            Objects.requireNonNull(hallazgo, "hallazgo");
        }
    }

    private final EventoSeguridadStore repositorio;
    private final MeterRegistry metricas;

    public EventoSeguridadService(EventoSeguridadStore repositorio, MeterRegistry metricas) {
        this.repositorio = repositorio;
        this.metricas = metricas;
    }

    public void registrar(RegistroEvento e) {
        Hallazgo h = e.hallazgo();
        metricas.counter(METRICA, "capa", h.capa().name(), "motivo", h.motivo().codigo()).increment();
        try {
            repositorio.insertar(new NuevoEvento(
                    e.conversacionId().orElse(null),
                    e.fkUsuario(),
                    h.capa().name(),
                    h.riesgo().name(),
                    h.motivo().codigo(),
                    e.textoNormalizado().map(Huellas::sha256).orElse(null)));
        } catch (RuntimeException ex) {
            log.warn("No se pudo registrar el evento de seguridad (capa {}): {}", h.capa(),
                    ex.getClass().getSimpleName());
        }
    }
}
