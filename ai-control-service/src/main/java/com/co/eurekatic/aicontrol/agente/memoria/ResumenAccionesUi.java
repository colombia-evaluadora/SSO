package com.co.eurekatic.aicontrol.agente.memoria;

import tools.jackson.core.type.TypeReference;
import tools.jackson.databind.json.JsonMapper;

import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

/**
 * Lo que la memoria recuerda de las acciones de UI de un turno, a partir del JSON que guarda
 * {@code ai.mensaje.acciones_ui}: ": rellenar nombres=Ana, cargo=COORDINADOR; resaltar fecha_ingreso". Sin esto el
 * modelo solo sabe que toco la pantalla, no que campos ni con que valores. Pura.
 */
final class ResumenAccionesUi {

    private static final JsonMapper JSON = JsonMapper.builder().build();
    private static final TypeReference<List<Map<String, Object>>> LISTA = new TypeReference<>() {};

    private ResumenAccionesUi() {
    }

    /** Vacio si no hay acciones o el JSON no se puede leer: la nota sigue sin el detalle. */
    static String de(String accionesUiJson) {
        if (accionesUiJson == null || accionesUiJson.isBlank()) {
            return "";
        }
        try {
            String acciones = JSON.readValue(accionesUiJson, LISTA).stream()
                    .map(ResumenAccionesUi::una)
                    .collect(Collectors.joining("; "));
            return acciones.isEmpty() ? "" : ": " + acciones;
        } catch (RuntimeException e) {
            return "";
        }
    }

    private static String una(Map<String, Object> accion) {
        String op = String.valueOf(accion.get("op"));
        return switch (op) {
            case "RELLENAR" -> "rellenar " + pares(accion.get("valores"));
            case "APLICAR_FILTROS" -> "filtrar " + pares(accion.get("filtros"));
            case "RESALTAR" -> "resaltar " + accion.get("campo");
            case "LIMPIAR_CAMPO" -> "limpiar " + accion.get("campo");
            case "NAVEGAR" -> "ir a " + accion.get("pantalla");
            case "ABRIR_PESTANA" -> "abrir pestana " + accion.get("pestana");
            default -> op.toLowerCase();
        };
    }

    private static String pares(Object mapa) {
        return mapa instanceof Map<?, ?> m
                ? m.entrySet().stream().map(e -> e.getKey() + "=" + e.getValue()).collect(Collectors.joining(", "))
                : "";
    }
}
