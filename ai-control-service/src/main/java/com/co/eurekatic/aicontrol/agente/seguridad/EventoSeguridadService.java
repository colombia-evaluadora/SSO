package com.co.eurekatic.aicontrol.agente.seguridad;

import com.co.eurekatic.aicontrol.agente.persistencia.EventoSeguridadRepository;
import com.co.eurekatic.aicontrol.agente.persistencia.EventoSeguridadRepository.NuevoEvento;
import io.micrometer.core.instrument.MeterRegistry;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.UUID;
import java.util.regex.Pattern;

/**
 * Registro de bloqueos y descartes del agente: {@code ai.evento_seguridad} y la
 * metrica {@code ai.firewall.bloqueos{capa,motivo}}.
 *
 * <p>Nunca guarda el texto, solo su huella SHA-256. El motivo tiene que ser un
 * codigo en mayusculas: si no lo es, se registra como {@code OTRO}, para que
 * ni el texto libre ni un valor nuevo disparen la cardinalidad de la metrica.
 *
 * <p>La metrica se cuenta antes de escribir en la base: si la base falla, el
 * bloqueo sigue contado y el turno no se tumba.
 */
@Service
public class EventoSeguridadService {

    private static final Logger log = LoggerFactory.getLogger(EventoSeguridadService.class);
    static final String METRICA = "ai.firewall.bloqueos";
    private static final Pattern MOTIVO_CODIGO = Pattern.compile("[A-Z0-9_]{1,40}");
    private static final String MOTIVO_GENERICO = "OTRO";

    /**
     * Un evento a registrar.
     *
     * @param conversacionId   conversacion donde ocurrio, o null si fue antes de crearla
     * @param fkUsuario        usuario dueno de la entrada
     * @param capa             filtro que actuo
     * @param riesgo           BAJO, MEDIO o ALTO
     * @param motivo           codigo de motivo; se sanea a OTRO si no es un codigo
     * @param textoNormalizado texto que se audita; solo se guarda su huella
     */
    public record RegistroEvento(UUID conversacionId, long fkUsuario, CapaSeguridad capa, Riesgo riesgo,
                                 String motivo, String textoNormalizado) {
    }

    private final EventoSeguridadRepository repositorio;
    private final MeterRegistry metricas;

    public EventoSeguridadService(EventoSeguridadRepository repositorio, MeterRegistry metricas) {
        this.repositorio = repositorio;
        this.metricas = metricas;
    }

    public void registrar(RegistroEvento e) {
        String motivo = motivoSeguro(e.motivo());
        metricas.counter(METRICA, "capa", e.capa().name(), "motivo", motivo).increment();
        try {
            repositorio.insertar(new NuevoEvento(e.conversacionId(), e.fkUsuario(), e.capa().name(),
                    e.riesgo().name(), motivo, huella(e.textoNormalizado())));
        } catch (RuntimeException ex) {
            log.warn("No se pudo registrar el evento de seguridad (capa {}): {}", e.capa(),
                    ex.getClass().getSimpleName());
        }
    }

    static String motivoSeguro(String motivo) {
        return motivo != null && MOTIVO_CODIGO.matcher(motivo).matches() ? motivo : MOTIVO_GENERICO;
    }

    /** SHA-256 en hexadecimal, 64 caracteres (cabe en CHAR(64)); null si no hay texto. */
    static String huella(String texto) {
        if (texto == null) {
            return null;
        }
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(texto.getBytes(StandardCharsets.UTF_8));
            return HexFormat.of().formatHex(digest);
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 no disponible en la JVM", e);
        }
    }
}
