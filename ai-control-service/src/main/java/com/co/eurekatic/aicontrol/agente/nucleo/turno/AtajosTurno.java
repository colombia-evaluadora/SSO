package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import com.co.eurekatic.aicontrol.agente.catalogo.turno.AccesoMenu;
import com.co.eurekatic.aicontrol.agente.comun.UsuarioAgente;
import com.co.eurekatic.aicontrol.agente.nucleo.AccionPropuesta;
import com.co.eurekatic.aicontrol.agente.nucleo.acciones.AccionesService;
import com.co.eurekatic.aicontrol.agente.nucleo.acciones.AfirmacionEnChat;
import com.co.eurekatic.aicontrol.agente.nucleo.intencion.Intencion;
import com.co.eurekatic.aicontrol.agente.nucleo.intencion.TipoIntencion;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import com.co.eurekatic.aicontrol.agente.ui.pantallas.BuscadorPantallas;
import com.co.eurekatic.aicontrol.agente.ui.pantallas.BuscarPantallaHerramienta;
import com.co.eurekatic.aicontrol.agente.ui.registro.Pantalla;
import com.co.eurekatic.aicontrol.agente.ui.registro.RegistroUiLoader;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

/**
 * Turnos que se resuelven sin el razonador, porque la respuesta correcta es determinista y el modelo la hace
 * peor: un "si" escrito con una accion pendiente (se recuerda el boton) y una pregunta de "donde esta" que el
 * registro de pantallas responde (se devuelve la pantalla con su enlace, sin nombres inventados).
 */
@Component
public class AtajosTurno {

    private final AccionesService acciones;
    private final RegistroUiLoader registro;

    public AtajosTurno(AccionesService acciones, RegistroUiLoader registro) {
        this.acciones = acciones;
        this.registro = registro;
    }

    /** La accion pendiente de la conversacion si el mensaje es una confirmacion escrita. */
    public Optional<AccionPropuesta> confirmacionEscrita(UUID conversacionId, UsuarioAgente usuario, String texto) {
        return AfirmacionEnChat.es(texto) ? acciones.pendienteVigente(conversacionId, usuario) : Optional.empty();
    }

    /** Con intencion de navegar, la pantalla que el registro encuentra entre los menus del usuario. */
    public Optional<RespuestaAgente.Ui> pantalla(Intencion intencion, String texto, Map<String, AccesoMenu> menus) {
        if (intencion.tipo() != TipoIntencion.NAVEGACION) {
            return Optional.empty();
        }
        List<Pantalla> encontradas = BuscadorPantallas.buscar(texto, registro.registro().pantallasVisibles(menus),
                BuscarPantallaHerramienta.MAXIMO);
        return encontradas.isEmpty() ? Optional.empty() : Optional.of(BuscarPantallaHerramienta.respuesta(encontradas));
    }
}
