package com.co.eurekatic.aicontrol.observaciones;

/**
 * Los dos resumenes que hoy concatena la base. Cada uno sabe de donde lee
 * sus fuentes, donde guarda, con que prompt se redacta y como se llama la
 * columna que cuenta lo que resumio.
 */
public enum TipoResumen {

    PERIODO("/informes/observacion/fuentes",
            "/informes/observacion/guardar",
            "OBSERVACIONES_ORIGEN",
            "prompts/system-periodo.st"),

    ANIO("/informes/observacion/final/fuentes",
            "/informes/observacion/final/guardar",
            "PERIODOS_ORIGEN",
            "prompts/system-anio.st");

    private final String rutaFuentes;
    private final String rutaGuardar;
    private final String campoOrigen;
    private final String systemPrompt;

    TipoResumen(String rutaFuentes, String rutaGuardar, String campoOrigen, String systemPrompt) {
        this.rutaFuentes = rutaFuentes;
        this.rutaGuardar = rutaGuardar;
        this.campoOrigen = campoOrigen;
        this.systemPrompt = systemPrompt;
    }

    public String rutaFuentes() { return rutaFuentes; }
    public String rutaGuardar() { return rutaGuardar; }
    public String campoOrigen() { return campoOrigen; }
    public String systemPrompt() { return systemPrompt; }
}
