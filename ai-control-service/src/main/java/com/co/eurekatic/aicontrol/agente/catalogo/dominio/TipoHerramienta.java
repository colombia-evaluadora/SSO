package com.co.eurekatic.aicontrol.agente.catalogo.dominio;

/**
 * Clase de una herramienta del agente. El comportamiento que cambia por clase
 * vive aqui, no en condicionales dispersos por el codigo.
 *
 * <ul>
 *   <li>LECTURA y ANALITICA: llaman a query-service con el token del usuario.</li>
 *   <li>ESCRITURA: nunca se ejecutan en el turno; producen una accion pendiente de confirmacion.</li>
 *   <li>NAVEGACION, UI y CONTROL: no tocan datos. CONTROL y UI devuelven su resultado directo al usuario.</li>
 * </ul>
 */
public enum TipoHerramienta {

    LECTURA(true, false, false),
    ANALITICA(true, false, false),
    ESCRITURA(false, true, false),
    NAVEGACION(false, false, false),
    UI(false, false, true),
    CONTROL(false, false, true);

    private final boolean ejecutaContraQueryService;
    private final boolean escribe;
    private final boolean devuelveDirecto;

    TipoHerramienta(boolean ejecutaContraQueryService, boolean escribe, boolean devuelveDirecto) {
        this.ejecutaContraQueryService = ejecutaContraQueryService;
        this.escribe = escribe;
        this.devuelveDirecto = devuelveDirecto;
    }

    /** Si el invocador de datos la ejecuta contra query-service en el turno. */
    public boolean ejecutaContraQueryService() {
        return ejecutaContraQueryService;
    }

    /** Si puede modificar datos: siempre pasa por confirmacion del usuario. */
    public boolean escribe() {
        return escribe;
    }

    /** Si el resultado va al usuario tal cual, sin que el modelo lo reformule. */
    public boolean devuelveDirecto() {
        return devuelveDirecto;
    }
}
