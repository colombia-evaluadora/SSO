package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import java.util.List;
import java.util.Map;

/**
 * Texto para la persona de cada herramienta mientras se ejecuta. Las de control y las mas comunes tienen
 * etiqueta propia; el resto se arma con el codigo ("sedes_listar" -> "Consultando sedes").
 */
public final class EtiquetasHerramientas {

    private static final Map<String, String> PROPIAS = Map.ofEntries(
            Map.entry("pedir_datos_faltantes", "Revisando qué datos faltan"),
            Map.entry("preparar_confirmacion", "Preparando la acción para que la confirmes"),
            Map.entry("buscar_pantalla", "Buscando la pantalla"),
            Map.entry("accion_ui", "Preparando cambios en la pantalla"),
            Map.entry("esquema_de_accion", "Revisando los datos que pide la acción"),
            Map.entry("consulta_analitica", "Calculando estadísticas"),
            Map.entry("mis_menus", "Revisando tus menús"),
            Map.entry("catalogo_valores", "Consultando las opciones disponibles"),
            Map.entry("planeador_estadisticas", "Calculando estadísticas del planeador"));

    private static final List<String> VERBOS_ESCRITURA = List.of("crear_", "editar_", "actualizar_", "vincular_",
            "asignar_", "calificar_", "registrar_", "observar_", "ponderar_", "estado_");

    private EtiquetasHerramientas() {
    }

    public static String de(String codigo) {
        String c = codigo == null ? "" : codigo;
        String propia = PROPIAS.get(c);
        if (propia != null) {
            return propia;
        }
        if (c.endsWith("_listar")) {
            return "Consultando " + humano(c.substring(0, c.length() - "_listar".length()));
        }
        if (c.endsWith("_detalle")) {
            return "Consultando el detalle de " + humano(c.substring(0, c.length() - "_detalle".length()));
        }
        if (VERBOS_ESCRITURA.stream().anyMatch(c::startsWith)) {
            return "Preparando: " + humano(c);
        }
        return "Consultando " + humano(c);
    }

    private static String humano(String codigo) {
        return codigo.replace('_', ' ').trim();
    }
}
