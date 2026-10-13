package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.turno.AccesoMenu;
import com.co.eurekatic.aicontrol.agente.nucleo.intencion.Intencion;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import org.springframework.ai.tool.ToolCallback;

import java.util.List;
import java.util.Map;

/**
 * Resultado de la preparacion de un turno: o se bloquea por seguridad, o queda listo para el razonador.
 */
public sealed interface Preparacion {

    /** La entrada es ALTO: el turno no llama al modelo y no se guarda el mensaje. */
    record Bloqueada(RespuestaAgente.Bloqueado respuesta) implements Preparacion {
    }

    /**
     * Turno listo para el razonador.
     *
     * @param textoNormalizado mensaje tras el firewall
     * @param intencion        intencion decidida por el router
     * @param herramientas     herramientas de datos del turno
     * @param callbacks        callbacks que se ofrecen al modelo
     * @param menus            menus que el usuario ve
     */
    record Listo(String textoNormalizado, Intencion intencion, List<HerramientaDef> herramientas,
                 List<ToolCallback> callbacks, Map<String, AccesoMenu> menus) implements Preparacion {

        public Listo {
            herramientas = List.copyOf(herramientas);
            callbacks = List.copyOf(callbacks);
            menus = Map.copyOf(menus);
        }
    }
}
