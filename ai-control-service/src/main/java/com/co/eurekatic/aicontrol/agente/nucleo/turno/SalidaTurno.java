package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import com.co.eurekatic.aicontrol.agente.seguridad.eventos.EventoSeguridadService;
import com.co.eurekatic.aicontrol.agente.seguridad.eventos.EventoSeguridadService.RegistroEvento;
import com.co.eurekatic.aicontrol.agente.seguridad.salida.ResultadoSalida;
import com.co.eurekatic.aicontrol.agente.seguridad.salida.SalidaSegura;
import org.springframework.stereotype.Component;

import java.util.Optional;
import java.util.UUID;

/**
 * Ultima revision de lo que sale hacia la persona. Una fuga del prompt bloquea la respuesta entera y
 * se registra; datos de contacto o tokens se redactan y la respuesta sigue.
 */
@Component
public class SalidaTurno {

    private final SalidaSegura salidaSegura;
    private final EventoSeguridadService eventos;

    public SalidaTurno(SalidaSegura salidaSegura, EventoSeguridadService eventos) {
        this.salidaSegura = salidaSegura;
        this.eventos = eventos;
    }

    public RespuestaAgente revisar(RespuestaAgente respuesta, UUID conversacionId, long userId) {
        ResultadoSalida general = salidaSegura.revisar(respuesta.texto());
        if (general.riesgo().bloquea()) {
            general.hallazgos().stream()
                    .filter(h -> h.riesgo().bloquea())
                    .findFirst()
                    .map(h -> new RegistroEvento(Optional.of(conversacionId), userId, h, Optional.empty()))
                    .ifPresent(eventos::registrar);
            return new RespuestaAgente.Bloqueado(general.texto());
        }
        return respuesta.transformarTextos(texto -> salidaSegura.revisar(texto).texto());
    }
}
