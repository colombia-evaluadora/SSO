package com.co.eurekatic.aicontrol.observaciones;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * Lo que devuelven los endpoints {@code .../fuentes}: las piezas a resumir y
 * lo que ya hay guardado.
 *
 * @param piezas         una por observacion (periodo) o por periodo (ano)
 * @param estudiante     primer nombre; nunca viaja al modelo
 * @param estadoGuardado APROBADA, MODIFICADA o null si todavia no hay texto
 */
public record Fuentes(List<Pieza> piezas, String estudiante, String estadoGuardado) {

    /** Una observacion o un resumen de periodo, con su contexto. */
    public record Pieza(String etiqueta, String contexto, String fecha, String texto) {}

    public boolean modificadaPorDocente() {
        return "MODIFICADA".equalsIgnoreCase(estadoGuardado);
    }

    /**
     * Convierte las filas del query-service. Las columnas de contexto del
     * estudiante vienen repetidas en cada fila; se toman de la primera.
     */
    public static Fuentes desdeFilas(TipoResumen tipo, List<Map<String, Object>> filas) {
        List<Pieza> piezas = new ArrayList<>(filas.size());
        for (Map<String, Object> f : filas) {
            piezas.add(switch (tipo) {
                case PERIODO -> new Pieza(str(f, "actividad"), str(f, "asignatura"),
                        fecha(f, "fecha"), str(f, "observacion"));
                case ANIO -> new Pieza(str(f, "periodo"), null,
                        rango(fecha(f, "fecha_inicio"), fecha(f, "fecha_fin")), str(f, "observacion"));
            });
        }
        Map<String, Object> primera = filas.isEmpty() ? Map.of() : filas.getFirst();
        return new Fuentes(piezas, str(primera, "estudiante"), str(primera, "estado_guardado"));
    }

    private static String rango(String desde, String hasta) {
        if (desde == null) return hasta;
        return hasta == null ? desde : desde + " a " + hasta;
    }

    /**
     * query-service serializa los DATE como timestamp ISO
     * ({@code 2026-08-31T00:00:00.000Z}); al modelo le basta el dia.
     */
    private static String fecha(Map<String, Object> fila, String columna) {
        String s = str(fila, columna);
        return s != null && s.length() > 10 && s.charAt(10) == 'T' ? s.substring(0, 10) : s;
    }

    /** El query-service puede devolver las columnas en mayusculas o minusculas. */
    private static String str(Map<String, Object> fila, String columna) {
        Object v = fila.get(columna);
        if (v == null) v = fila.get(columna.toUpperCase());
        if (v == null) return null;
        String s = v.toString().trim();
        return s.isEmpty() ? null : s;
    }
}
