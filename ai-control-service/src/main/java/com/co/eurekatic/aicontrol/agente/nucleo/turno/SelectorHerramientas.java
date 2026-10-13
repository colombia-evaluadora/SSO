package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import com.co.eurekatic.aicontrol.agente.catalogo.carga.CatalogoHerramientasLoader;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.TipoHerramienta;
import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.FabricaToolCallbacks;
import com.co.eurekatic.aicontrol.agente.catalogo.turno.HerramientasDelTurno;
import com.co.eurekatic.aicontrol.agente.catalogo.turno.MenusUsuario;
import com.co.eurekatic.aicontrol.agente.comun.UsuarioAgente;
import com.co.eurekatic.aicontrol.agente.nucleo.control.ProveedorHerramientasControl;
import com.co.eurekatic.aicontrol.agente.nucleo.intencion.Intencion;
import org.springframework.ai.tool.ToolCallback;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.List;
import java.util.Set;

/**
 * Herramientas que el modelo ve en un turno: las de datos filtradas por intencion, menus, roles y
 * riesgo, mas las de control si la intencion las admite. Es el minimo privilegio del turno.
 */
@Component
public class SelectorHerramientas {

    private final MenusUsuario menus;
    private final CatalogoHerramientasLoader catalogo;
    private final HerramientasDelTurno filtro;
    private final FabricaToolCallbacks fabrica;
    private final List<ProveedorHerramientasControl> controles;

    public SelectorHerramientas(MenusUsuario menus, CatalogoHerramientasLoader catalogo, HerramientasDelTurno filtro,
                                FabricaToolCallbacks fabrica, List<ProveedorHerramientasControl> controles) {
        this.menus = menus;
        this.catalogo = catalogo;
        this.filtro = filtro;
        this.fabrica = fabrica;
        this.controles = List.copyOf(controles);
    }

    /** Herramientas de datos del turno y los callbacks de todas las que el modelo ve. */
    public Seleccion para(UsuarioAgente usuario, Intencion intencion) {
        Set<TipoHerramienta> tipos = intencion.tipo().herramientasPermitidas();
        List<HerramientaDef> herramientas = filtro.calcular(catalogo.catalogo(), usuario.roles(),
                menus.de(usuario.userId()), intencion.riesgo(), tipos);
        List<ToolCallback> callbacks = new ArrayList<>(fabrica.crearTodas(herramientas));
        if (tipos.contains(TipoHerramienta.CONTROL)) {
            controles.forEach(proveedor -> callbacks.addAll(proveedor.callbacks()));
        }
        return new Seleccion(herramientas, List.copyOf(callbacks));
    }

    /**
     * @param herramientas herramientas de datos que el modelo puede usar en el turno
     * @param callbacks    todos los callbacks que se ofrecen al modelo
     */
    public record Seleccion(List<HerramientaDef> herramientas, List<ToolCallback> callbacks) {

        public Seleccion {
            herramientas = List.copyOf(herramientas);
            callbacks = List.copyOf(callbacks);
        }
    }
}
