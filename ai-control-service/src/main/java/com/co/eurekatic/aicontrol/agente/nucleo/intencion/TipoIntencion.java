package com.co.eurekatic.aicontrol.agente.nucleo.intencion;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.TipoHerramienta;

import java.util.Set;

/**
 * Que quiere hacer la persona. Cada tipo fija que clases de herramienta puede ver el modelo en el
 * turno: es el primer filtro de minimo privilegio, antes de menus y roles.
 */
public enum TipoIntencion {

    ACCION(Set.of(TipoHerramienta.LECTURA, TipoHerramienta.ESCRITURA, TipoHerramienta.CONTROL)),
    CONSULTA(Set.of(TipoHerramienta.LECTURA, TipoHerramienta.CONTROL)),
    ANALITICA(Set.of(TipoHerramienta.ANALITICA, TipoHerramienta.LECTURA, TipoHerramienta.CONTROL)),
    NAVEGACION(Set.of(TipoHerramienta.CONTROL, TipoHerramienta.LECTURA)),
    UI(Set.of(TipoHerramienta.CONTROL, TipoHerramienta.LECTURA)),
    CHARLA(Set.of());

    private final Set<TipoHerramienta> herramientasPermitidas;

    TipoIntencion(Set<TipoHerramienta> herramientasPermitidas) {
        this.herramientasPermitidas = herramientasPermitidas;
    }

    /** Clases de herramienta que el turno puede ofrecer al modelo con esta intencion. */
    public Set<TipoHerramienta> herramientasPermitidas() {
        return herramientasPermitidas;
    }
}
