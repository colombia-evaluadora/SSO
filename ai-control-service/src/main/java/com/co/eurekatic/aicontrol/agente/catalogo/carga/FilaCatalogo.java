package com.co.eurekatic.aicontrol.agente.catalogo.carga;

import java.util.List;

/**
 * Fila tal como la devuelve {@code ai.fn_herramienta_catalogo_interno()}: texto y JSON sin
 * interpretar. Los campos nulos son el reflejo de columnas nulas de la base (una herramienta
 * de control no tiene ruta, por ejemplo); el mapeo a dominio es quien decide que hacer con ellos.
 */
public record FilaCatalogo(
        long id,
        String codigo,
        String tipo,
        String descripcionModelo,
        String parametrosJson,
        boolean requiereConfirmacion,
        String ejemplosJson,
        int version,
        String menuCodigo,
        String pathTemplate,
        String httpMethod,
        String paramTypesJson,
        String restriccionesJson,
        List<String> roles,
        String avisoConfirmacion) {

    public FilaCatalogo {
        roles = roles == null ? List.of() : List.copyOf(roles);
        avisoConfirmacion = avisoConfirmacion == null ? "" : avisoConfirmacion;
    }

    /** Fila sin aviso de confirmacion. */
    public FilaCatalogo(long id, String codigo, String tipo, String descripcionModelo, String parametrosJson,
                        boolean requiereConfirmacion, String ejemplosJson, int version, String menuCodigo,
                        String pathTemplate, String httpMethod, String paramTypesJson, String restriccionesJson,
                        List<String> roles) {
        this(id, codigo, tipo, descripcionModelo, parametrosJson, requiereConfirmacion, ejemplosJson, version,
                menuCodigo, pathTemplate, httpMethod, paramTypesJson, restriccionesJson, roles, "");
    }
}
