package com.co.eurekatic.reporting.render;

import com.co.eurekatic.reporting.config.ReportingProperties;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Decide qué columnas salen y cuánto ancho le toca a cada una.
 *
 * <p>Repartir el ancho en partes iguales es lo que hace que una tabla se vea
 * generada: "Documento" (11 caracteres) recibe lo mismo que "Nombre completo"
 * (que puede llegar a 40), así que una sobra vacía mientras la otra parte
 * todas sus filas en dos líneas. Acá el ancho se mide contra el contenido
 * real.
 */
final class ColumnLayout {

    private ColumnLayout() {}

    /** Cuántas filas se miran para medir. Más no cambia el reparto y sí cuesta. */
    private static final int MUESTRA = 300;

    /**
     * Percentil en vez del máximo: un único nombre absurdamente largo no debe
     * decidir el ancho de la columna para las otras mil filas. Se acepta que
     * ese caso extremo se estire a dos líneas.
     */
    private static final double PERCENTIL = 0.90;

    /** Ninguna columna baja de esto, aunque su contenido sea de un carácter. */
    private static final int MIN_CARACTERES = 8;

    /** Ni pasa de esto, aunque el contenido sea larguísimo. */
    private static final int MAX_CARACTERES = 42;

    /**
     * Las columnas configuradas; si no hay, las claves de la primera fila.
     *
     * <p>Se usa la primera fila y no la unión de todas porque las filas de una
     * misma consulta comparten forma, y recorrerlas todas para descubrir
     * columnas costaría una pasada completa sobre un resultado que puede ser
     * enorme.
     */
    static Map<String, String> resolver(ReportingProperties.Report def,
                                        List<Map<String, Object>> rows) {
        if (def != null && def.getColumns() != null && !def.getColumns().isEmpty()) {
            return def.getColumns();
        }
        Map<String, String> auto = new LinkedHashMap<>();
        if (!rows.isEmpty()) {
            for (String k : rows.get(0).keySet()) {
                auto.put(k, k);
            }
        }
        return auto;
    }

    /**
     * Ancho en puntos de cada columna, en el orden de {@code columnas} y
     * sumando exactamente {@code anchoTotal}.
     */
    static int[] anchos(Map<String, String> columnas,
                        List<Map<String, Object>> rows,
                        int anchoTotal) {

        int n = columnas.size();
        if (n == 0) {
            return new int[0];
        }

        // 1) Peso de cada columna = cuántos caracteres necesita.
        double[] pesos = new double[n];
        double suma = 0;
        int i = 0;
        for (Map.Entry<String, String> e : columnas.entrySet()) {
            int necesita = Math.max(
                    e.getValue() == null ? 0 : e.getValue().length(),
                    anchoDelContenido(e.getKey(), rows));
            pesos[i] = Math.min(Math.max(necesita, MIN_CARACTERES), MAX_CARACTERES);
            suma += pesos[i];
            i++;
        }

        // 2) Repartir el ancho disponible en proporción a esos pesos.
        int[] anchos = new int[n];
        int asignado = 0;
        for (int j = 0; j < n; j++) {
            anchos[j] = (int) Math.floor(anchoTotal * (pesos[j] / suma));
            asignado += anchos[j];
        }

        // 3) El redondeo hacia abajo deja algunos puntos sin asignar; se los
        //    lleva la columna más ancha. Si no, la tabla no llega al margen
        //    derecho y el encabezado queda desalineado con las filas.
        if (asignado < anchoTotal) {
            int masAncha = 0;
            for (int j = 1; j < n; j++) {
                if (anchos[j] > anchos[masAncha]) masAncha = j;
            }
            anchos[masAncha] += anchoTotal - asignado;
        }

        return anchos;
    }

    /** Largo del contenido de una columna, en el percentil configurado. */
    private static int anchoDelContenido(String clave, List<Map<String, Object>> rows) {
        if (rows.isEmpty()) {
            return 0;
        }
        int hasta = Math.min(rows.size(), MUESTRA);
        List<Integer> largos = new ArrayList<>(hasta);
        for (int i = 0; i < hasta; i++) {
            largos.add(CellValues.toText(rows.get(i).get(clave)).length());
        }
        int[] ordenados = largos.stream().mapToInt(Integer::intValue).sorted().toArray();
        int idx = (int) Math.floor(PERCENTIL * (ordenados.length - 1));
        return ordenados[Math.max(idx, 0)];
    }

    /** Solo para los tests: deja verificar el reparto sin construir un PDF. */
    static String describir(Map<String, String> columnas, int[] anchos) {
        return columnas.keySet() + " -> " + Arrays.toString(anchos);
    }
}
