package com.co.eurekatic.aicontrol.agente.web;

import com.co.eurekatic.aicontrol.agente.comun.ErrorAgente;
import com.co.eurekatic.aicontrol.agente.comun.UsuarioAgente;
import com.co.eurekatic.aicontrol.agente.nucleo.acciones.AccionesService;
import com.co.eurekatic.aicontrol.agente.nucleo.turno.AgenteService;
import com.co.eurekatic.aicontrol.agente.nucleo.turno.ConversacionesService;
import com.co.eurekatic.aicontrol.agente.web.dto.ConversacionesDto;
import com.co.eurekatic.aicontrol.agente.web.dto.MensajeRequest;
import com.co.eurekatic.aicontrol.agente.web.dto.RespuestaDto;
import com.co.eurekatic.aicontrol.config.agente.AgenteProperties;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.servlet.mvc.method.annotation.SseEmitter;
import tools.jackson.databind.json.JsonMapper;

import java.util.List;
import java.util.UUID;

/**
 * Endpoints del agente conversacional, bajo {@code /api/ai/agente} por el gateway. Cada operacion
 * valida que la conversacion o la accion sea del usuario del token; si no lo es, responde 404.
 */
@RestController
@RequestMapping("/ai/agente")
public class AgenteController {

    private static final int TAMANO_MAXIMO_PAGINA = 50;
    private static final int TAMANO_PAGINA_POR_DEFECTO = 20;

    private final ConversacionesService conversaciones;
    private final AgenteService agente;
    private final AccionesService acciones;
    private final AgenteProperties props;
    private final JsonMapper json;
    private final TransmisorTurno transmisor;

    public AgenteController(ConversacionesService conversaciones, AgenteService agente, AccionesService acciones,
                            AgenteProperties props, JsonMapper json, TransmisorTurno transmisor) {
        this.conversaciones = conversaciones;
        this.agente = agente;
        this.acciones = acciones;
        this.props = props;
        this.json = json;
        this.transmisor = transmisor;
    }

    @PostMapping("/conversaciones")
    @ResponseStatus(HttpStatus.CREATED)
    public ConversacionesDto.Creada crear(Authentication autenticacion) {
        return new ConversacionesDto.Creada(conversaciones.crear(UsuarioActual.de(autenticacion)));
    }

    @GetMapping("/conversaciones")
    public List<ConversacionesDto.Resumen> listar(
            @RequestParam(name = "page", defaultValue = "0") int page,
            @RequestParam(name = "size", defaultValue = "" + TAMANO_PAGINA_POR_DEFECTO) int size,
            Authentication autenticacion) {
        int tamano = Math.min(Math.max(size, 1), TAMANO_MAXIMO_PAGINA);
        return conversaciones.listar(UsuarioActual.de(autenticacion), Math.max(page, 0), tamano).stream()
                .map(ConversacionesDto.Resumen::de)
                .toList();
    }

    @GetMapping("/conversaciones/{id}")
    public ConversacionesDto.Detalle detalle(@PathVariable UUID id, Authentication autenticacion) {
        return ConversacionesDto.Detalle.de(conversaciones.detalle(id, UsuarioActual.de(autenticacion)));
    }

    @PutMapping("/conversaciones/{id}/archivar")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void archivar(@PathVariable UUID id, Authentication autenticacion) {
        conversaciones.archivar(id, UsuarioActual.de(autenticacion));
    }

    @PostMapping("/conversaciones/{id}/mensajes")
    public RespuestaDto mensaje(@PathVariable UUID id, @Valid @RequestBody MensajeRequest peticion,
                                Authentication autenticacion) {
        UsuarioAgente usuario = UsuarioActual.de(autenticacion);
        validarLongitud(peticion);
        return RespuestaDto.de(agente.procesar(id, usuario, peticion.texto(), contextoUi(peticion)));
    }

    /**
     * Mismo turno por Server-Sent Events: eventos {@code estado} mientras avanza y {@code respuesta} o
     * {@code error} al final. Los errores previos al turno (identidad, longitud) responden como siempre.
     */
    @PostMapping(value = "/conversaciones/{id}/mensajes/stream", produces = MediaType.TEXT_EVENT_STREAM_VALUE)
    public SseEmitter mensajeStream(@PathVariable UUID id, @Valid @RequestBody MensajeRequest peticion,
                                    Authentication autenticacion) {
        UsuarioAgente usuario = UsuarioActual.de(autenticacion);
        validarLongitud(peticion);
        return transmisor.transmitir(id, usuario, peticion.texto(), contextoUi(peticion));
    }

    /**
     * Corta el turno en curso de la conversacion (sincrono o por streaming) y libera el turno del usuario.
     * {@code cancelado} es false si no habia ninguno en marcha. El turno cortado termina con una respuesta
     * "Cancelaste la petición." que queda en el historial.
     */
    @PostMapping("/conversaciones/{id}/cancelar")
    public ConversacionesDto.Cancelacion cancelarTurno(@PathVariable UUID id, Authentication autenticacion) {
        return new ConversacionesDto.Cancelacion(agente.cancelar(id, UsuarioActual.de(autenticacion)));
    }

    private void validarLongitud(MensajeRequest peticion) {
        if (peticion.texto().length() > props.limites().textoMaxCaracteres()) {
            throw new ErrorAgente.PeticionInvalida("El mensaje supera el máximo de "
                    + props.limites().textoMaxCaracteres() + " caracteres.");
        }
    }

    /** El contexto de pantalla serializado; uno enorme se rechaza antes de llegar al turno. */
    private String contextoUi(MensajeRequest peticion) {
        String contexto = peticion.contextoUi() == null ? "" : json.writeValueAsString(peticion.contextoUi());
        if (contexto.length() > props.limites().contextoMaxCaracteres()) {
            throw new ErrorAgente.PeticionInvalida("El contexto de la pantalla es demasiado grande.");
        }
        return contexto;
    }

    @PostMapping("/acciones/{id}/confirmar")
    public RespuestaDto confirmar(@PathVariable UUID id, Authentication autenticacion) {
        return RespuestaDto.de(acciones.confirmar(id, UsuarioActual.de(autenticacion)));
    }

    @PostMapping("/acciones/{id}/cancelar")
    public RespuestaDto cancelar(@PathVariable UUID id, Authentication autenticacion) {
        return RespuestaDto.de(acciones.cancelar(id, UsuarioActual.de(autenticacion)));
    }
}
