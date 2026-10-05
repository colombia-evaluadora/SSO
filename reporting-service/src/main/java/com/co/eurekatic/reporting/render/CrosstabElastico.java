package com.co.eurekatic.reporting.render;

import net.sf.jasperreports.crosstabs.JRCrosstabCell;
import net.sf.jasperreports.crosstabs.JRCrosstabColumnGroup;
import net.sf.jasperreports.crosstabs.JRCrosstabRowGroup;
import net.sf.jasperreports.crosstabs.design.JRDesignCellContents;
import net.sf.jasperreports.crosstabs.design.JRDesignCrosstab;
import net.sf.jasperreports.crosstabs.design.JRDesignCrosstabCell;
import net.sf.jasperreports.crosstabs.design.JRDesignCrosstabRowGroup;
import net.sf.jasperreports.engine.JRBand;
import net.sf.jasperreports.engine.JRChild;
import net.sf.jasperreports.engine.design.JRDesignElement;
import net.sf.jasperreports.engine.design.JasperDesign;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Crosstabs que ocupan siempre el mismo ancho, repartido entre las columnas
 * que traigan los datos (los periodos del boletin, los niveles de la escala).
 *
 * <p>Jasper fija el ancho de cada columna de un crosstab al diseñarlo y no
 * acepta expresiones: con pocos periodos la tabla quedaba angosta y con
 * muchos partia columnas a otro bloque. Aqui, antes de compilar, se cuentan
 * las columnas que llegaran y se recalculan los anchos. Lo declara la
 * plantilla con propiedades del crosstab:
 * <ul>
 *   <li>{@code sso.columnas.campo}: campo cuyos valores distintos son las columnas.</li>
 *   <li>{@code sso.columnas.filtro}: opcional, {@code campo=valor} que deben cumplir las filas contadas.</li>
 *   <li>{@code sso.columnas.max}: ancho maximo de una columna.</li>
 *   <li>{@code sso.fila.elastica}: opcional, grupo de filas (la columna de
 *       nombres) que absorbe el ancho sobrante; {@code sso.fila.minimo} su ancho minimo.</li>
 * </ul>
 * Sin fila elastica, las columnas se reparten todo el ancho disponible.
 */
final class CrosstabElastico {

    static final String CAMPO = "sso.columnas.campo";
    static final String FILTRO = "sso.columnas.filtro";
    static final String MAX = "sso.columnas.max";
    static final String ELASTICA = "sso.fila.elastica";
    static final String MINIMO = "sso.fila.minimo";

    /** Tolerancia para decidir si un elemento llega al borde que se mueve. */
    private static final int TOLERANCIA = 10;

    private CrosstabElastico() {}

    /** Los crosstabs elasticos de la plantilla. */
    static List<JRDesignCrosstab> de(JasperDesign d) {
        List<JRDesignCrosstab> out = new ArrayList<>();
        for (JRBand banda : d.getAllBands()) {
            for (JRChild hijo : banda.getChildren()) {
                if (hijo instanceof JRDesignCrosstab c && c.getPropertiesMap().containsProperty(CAMPO)) {
                    out.add(c);
                }
            }
        }
        return out;
    }

    /** Cuantas columnas traen las filas para un crosstab: valores distintos del campo. */
    static int columnas(JRDesignCrosstab c, List<Map<String, Object>> rows) {
        String campo = c.getPropertiesMap().getProperty(CAMPO);
        String filtro = c.getPropertiesMap().getProperty(FILTRO);
        String fCampo = null;
        String fValor = null;
        if (filtro != null && filtro.contains("=")) {
            fCampo = filtro.substring(0, filtro.indexOf('=')).trim();
            fValor = filtro.substring(filtro.indexOf('=') + 1).trim();
        }
        Set<String> valores = new HashSet<>();
        for (Map<String, Object> row : rows) {
            if (fCampo != null && fValor != null && !fValor.equals(String.valueOf(row.get(fCampo)))) {
                continue;
            }
            Object v = row.get(campo);
            if (v != null && !v.toString().isBlank()) {
                valores.add(v.toString());
            }
        }
        return Math.max(1, valores.size());
    }

    /** Recalcula los anchos de un crosstab para {@code n} columnas. */
    static void ajustar(JRDesignCrosstab c, int n) {
        int ancho = c.getWidth();
        int max = entero(c, MAX, 60);
        String nombreElastica = c.getPropertiesMap().getProperty(ELASTICA);

        int filas = 0;
        JRDesignCrosstabRowGroup elastica = null;
        int antesDeElastica = 0;
        for (JRCrosstabRowGroup g : c.getRowGroups()) {
            if (g.getName().equals(nombreElastica)) {
                elastica = (JRDesignCrosstabRowGroup) g;
                antesDeElastica = filas;
            }
            filas += g.getWidth();
        }

        List<JRCrosstabCell> celdas = c.getCellsList();
        int columnaVieja = celdas.isEmpty() ? max : celdas.get(0).getWidth();
        int columna;
        if (elastica != null) {
            int fijas = filas - elastica.getWidth();
            int minimo = entero(c, MINIMO, 120);
            columna = Math.min(max, Math.max(1, (ancho - fijas - minimo) / n));
            int nuevaElastica = ancho - fijas - n * columna;
            int delta = nuevaElastica - elastica.getWidth();
            if (delta != 0) {
                mover(elastica.getHeader(), elastica.getWidth(), delta);
                // La esquina abarca todos los grupos de filas: lo que esta a
                // la derecha de la elastica se corre, lo que la cruza crece.
                mover(c.getHeaderCell(), antesDeElastica + elastica.getWidth(), delta);
                elastica.setWidth(nuevaElastica);
            }
        } else {
            columna = Math.min(max, Math.max(1, (ancho - filas) / n));
        }

        int delta = columna - columnaVieja;
        if (delta != 0) {
            for (JRCrosstabCell celda : celdas) {
                ((JRDesignCrosstabCell) celda).setWidth(columna);
                mover(celda.getContents(), columnaVieja, delta);
            }
            for (JRCrosstabColumnGroup g : c.getColumnGroups()) {
                mover(g.getHeader(), columnaVieja, delta);
            }
        }
        c.preprocess();
    }

    /**
     * Ensancha un contenedor cuyo borde {@code limite} se corre {@code delta}:
     * lo que empieza en o despues del borde se desplaza, lo que llega a el crece.
     */
    private static void mover(Object contenido, int limite, int delta) {
        if (!(contenido instanceof JRDesignCellContents cc)) {
            return;
        }
        for (JRChild hijo : cc.getChildren()) {
            if (!(hijo instanceof JRDesignElement e)) {
                continue;
            }
            if (e.getX() >= limite) {
                e.setX(e.getX() + delta);
            } else if (e.getX() + e.getWidth() >= limite - TOLERANCIA) {
                e.setWidth(Math.max(1, e.getWidth() + delta));
            }
        }
    }

    private static int entero(JRDesignCrosstab c, String propiedad, int porDefecto) {
        String v = c.getPropertiesMap().getProperty(propiedad);
        try {
            return v == null ? porDefecto : Integer.parseInt(v.trim());
        } catch (NumberFormatException e) {
            return porDefecto;
        }
    }
}
