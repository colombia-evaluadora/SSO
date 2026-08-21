package com.co.eurekatic.reporting.render;

import com.co.eurekatic.reporting.config.ReportingProperties;
import net.sf.jasperreports.engine.JRException;
import net.sf.jasperreports.engine.JasperCompileManager;
import net.sf.jasperreports.engine.JasperFillManager;
import net.sf.jasperreports.engine.JasperPrint;
import net.sf.jasperreports.engine.JasperReport;
import net.sf.jasperreports.engine.data.JRMapCollectionDataSource;
import net.sf.jasperreports.engine.design.JRDesignBand;
import net.sf.jasperreports.engine.design.JRDesignExpression;
import net.sf.jasperreports.engine.design.JRDesignField;
import net.sf.jasperreports.engine.design.JRDesignStaticText;
import net.sf.jasperreports.engine.design.JRDesignTextField;
import net.sf.jasperreports.engine.design.JasperDesign;
// OJO: en JasperReports 7 el exportador PDF NO esta en
// net.sf.jasperreports.engine.export (ahi vivia en 6.x): se movio al
// modulo jasperreports-pdf, bajo net.sf.jasperreports.pdf.
import net.sf.jasperreports.pdf.JRPdfExporter;
import net.sf.jasperreports.engine.type.HorizontalTextAlignEnum;
import net.sf.jasperreports.engine.type.ModeEnum;
import net.sf.jasperreports.engine.type.OrientationEnum;
import net.sf.jasperreports.engine.type.TextAdjustEnum;
import net.sf.jasperreports.engine.type.WhenNoDataTypeEnum;
import net.sf.jasperreports.export.SimpleExporterInput;
import net.sf.jasperreports.export.SimpleOutputStreamExporterOutput;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.core.io.ClassPathResource;
import org.springframework.stereotype.Component;

import java.awt.Color;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.time.LocalDate;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Genera el PDF con JasperReports.
 *
 * <p>Dos caminos, y el orden importa:
 * <ol>
 *   <li>Si existe {@code classpath:reportes/{clave}.jrxml}, se usa esa
 *       plantilla. Es el camino para los reportes con diseno propio —
 *       membrete, agrupaciones, totales— disenados en Jaspersoft Studio.</li>
 *   <li>Si no existe, se arma una tabla generica con las columnas
 *       configuradas.</li>
 * </ol>
 *
 * <p>El segundo camino existe para que sumar un dominio no dependa de
 * que alguien abra Jaspersoft Studio: con la fila {@code query} y unas
 * lineas de YAML el reporte ya sale, y el {@code .jrxml} se agrega
 * despues sin tocar codigo. Un reporte que tarda una semana en existir
 * porque falta el diseno es un reporte que no existe.
 *
 * <p>Las plantillas compiladas se cachean: compilar un {@code .jrxml}
 * cuesta bastante mas que llenarlo, y no cambian en caliente.
 */
@Component
public class PdfRenderer {

    private static final Logger log = LoggerFactory.getLogger(PdfRenderer.class);

    private static final DateTimeFormatter FECHA = DateTimeFormatter.ofPattern("dd/MM/yyyy");

    /** A4 apaisado, en puntos. Los listados son anchos. */
    private static final int PAGE_WIDTH = 842;
    private static final int PAGE_HEIGHT = 595;
    private static final int MARGIN = 24;
    private static final int ROW_HEIGHT = 16;

    private final Map<String, JasperReport> compiladas = new ConcurrentHashMap<>();

    public byte[] render(String clave,
                         ReportingProperties.Report def,
                         List<Map<String, Object>> rows) {
        try {
            Map<String, String> columnas = resolveColumns(def, rows);
            JasperReport report = compiladas.computeIfAbsent(
                    clave, k -> compile(k, def, columnas));

            Map<String, Object> params = new HashMap<>();
            params.put("TITULO", def.getTitle() == null ? clave : def.getTitle());
            params.put("GENERADO", LocalDate.now().format(FECHA));
            params.put("TOTAL", rows.size());

            // JRMapCollectionDataSource lee cada fila como Map, que es
            // justo lo que devuelve el query-service. No hace falta un
            // bean intermedio por dominio.
            JasperPrint print = JasperFillManager.fillReport(
                    report, params, new JRMapCollectionDataSource(normalize(rows, columnas)));

            ByteArrayOutputStream out = new ByteArrayOutputStream();
            JRPdfExporter exporter = new JRPdfExporter();
            exporter.setExporterInput(new SimpleExporterInput(print));
            exporter.setExporterOutput(new SimpleOutputStreamExporterOutput(out));
            exporter.exportReport();
            return out.toByteArray();

        } catch (JRException e) {
            throw new IllegalStateException(
                    "No se pudo generar el PDF del reporte '" + clave + "'", e);
        }
    }

    /**
     * Columnas declaradas en la config; si no hay, las claves de la
     * primera fila. Se usa la primera fila y no la union de todas
     * porque las filas de una misma consulta comparten forma, y
     * recorrerlas todas para descubrir columnas costaria una pasada
     * completa sobre un resultado que puede ser enorme.
     */
    private Map<String, String> resolveColumns(ReportingProperties.Report def,
                                               List<Map<String, Object>> rows) {
        if (def.getColumns() != null && !def.getColumns().isEmpty()) {
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
     * Deja solo las columnas pedidas y aplana los valores a texto.
     *
     * <p>Aplanar es necesario: varias funciones devuelven columnas
     * agregadas como JSON (roles, sedes), y un objeto anidado impreso
     * de una celda sale como su {@code toString()} de Java. Convertirlo
     * aca deja el mismo texto en el PDF y en el Excel.
     */
    private List<Map<String, ?>> normalize(List<Map<String, Object>> rows,
                                           Map<String, String> columnas) {
        // Bucle y no stream: el cast de Map<String,Object> a Map<String,?>
        // dentro del map() hace que se infiera List<Map<String,capture-of-?>>,
        // que no es asignable a List<Map<String,?>>. Con add() sobre la lista
        // ya tipada, el subtipado se resuelve sin cast.
        List<Map<String, ?>> out = new ArrayList<>(rows.size());
        for (Map<String, Object> row : rows) {
            Map<String, Object> limpia = new LinkedHashMap<>();
            for (String col : columnas.keySet()) {
                limpia.put(col, CellValues.toText(row.get(col)));
            }
            out.add(limpia);
        }
        return out;
    }

    private JasperReport compile(String clave,
                                 ReportingProperties.Report def,
                                 Map<String, String> columnas) {
        try {
            ClassPathResource plantilla = new ClassPathResource("reportes/" + clave + ".jrxml");
            if (plantilla.exists()) {
                try (InputStream in = plantilla.getInputStream()) {
                    log.info("Reporte '{}': usando plantilla reportes/{}.jrxml", clave, clave);
                    return JasperCompileManager.compileReport(in);
                }
            }
            log.info("Reporte '{}': sin plantilla propia, se arma tabla generica de {} columnas",
                    clave, columnas.size());
            return JasperCompileManager.compileReport(genericDesign(def, columnas));
        } catch (JRException | IOException e) {
            throw new IllegalStateException(
                    "No se pudo compilar el reporte '" + clave + "'", e);
        }
    }

    /** Tabla generica: titulo, encabezados repetidos por pagina y una
     *  fila por registro, con el ancho repartido en partes iguales. */
    private JasperDesign genericDesign(ReportingProperties.Report def,
                                       Map<String, String> columnas) throws JRException {
        JasperDesign design = new JasperDesign();
        design.setName("generico");
        design.setPageWidth(PAGE_WIDTH);
        design.setPageHeight(PAGE_HEIGHT);
        design.setOrientation(OrientationEnum.LANDSCAPE);
        design.setLeftMargin(MARGIN);
        design.setRightMargin(MARGIN);
        design.setTopMargin(MARGIN);
        design.setBottomMargin(MARGIN);
        design.setColumnWidth(PAGE_WIDTH - 2 * MARGIN);
        // Sin esto, un reporte cuyo filtro no encontro nada sale como un
        // archivo de cero paginas, que el visor abre como "corrupto". Con
        // el titulo se ve que la consulta corrio y no hubo resultados.
        design.setWhenNoDataType(WhenNoDataTypeEnum.ALL_SECTIONS_NO_DETAIL);

        design.addParameter(param("TITULO", String.class));
        design.addParameter(param("GENERADO", String.class));
        design.addParameter(param("TOTAL", Integer.class));

        for (String col : columnas.keySet()) {
            JRDesignField f = new JRDesignField();
            f.setName(col);
            f.setValueClass(String.class);
            design.addField(f);
        }

        int usable = PAGE_WIDTH - 2 * MARGIN;
        int n = Math.max(columnas.size(), 1);
        int colWidth = usable / n;

        // --- titulo ---
        JRDesignBand title = new JRDesignBand();
        title.setHeight(46);
        title.addElement(staticExpr("$P{TITULO}", 0, 0, usable, 22, 14f, true,
                HorizontalTextAlignEnum.LEFT));
        title.addElement(staticExpr(
                "\"Generado el \" + $P{GENERADO} + \" · \" + $P{TOTAL} + \" registro(s)\"",
                0, 24, usable, 14, 8f, false, HorizontalTextAlignEnum.LEFT));
        design.setTitle(title);

        // --- encabezados (se repiten en cada pagina) ---
        JRDesignBand header = new JRDesignBand();
        header.setHeight(ROW_HEIGHT + 4);
        int x = 0;
        for (Map.Entry<String, String> e : columnas.entrySet()) {
            JRDesignStaticText th = new JRDesignStaticText();
            th.setText(e.getValue());
            th.setX(x);
            th.setY(2);
            th.setWidth(colWidth);
            th.setHeight(ROW_HEIGHT);
            th.setMode(ModeEnum.OPAQUE);
            th.setBackcolor(new Color(0xEE, 0xF1, 0xF5));
            th.setFontSize(8f);
            th.setBold(true);
            header.addElement(th);
            x += colWidth;
        }
        design.setColumnHeader(header);

        // --- detalle ---
        JRDesignBand detail = new JRDesignBand();
        detail.setHeight(ROW_HEIGHT);
        x = 0;
        for (String col : columnas.keySet()) {
            JRDesignTextField td = new JRDesignTextField();
            JRDesignExpression expr = new JRDesignExpression();
            expr.setText("$F{" + col + "}");
            td.setExpression(expr);
            td.setX(x);
            td.setY(0);
            td.setWidth(colWidth);
            td.setHeight(ROW_HEIGHT);
            td.setFontSize(8f);
            // Un nombre largo no debe empujar la columna siguiente ni
            // desaparecer: se estira la fila.
            // Jasper 7: setStretchWithOverflow(true) se reemplazo por
            // setTextAdjust(STRETCH_HEIGHT).
            td.setTextAdjust(TextAdjustEnum.STRETCH_HEIGHT);
            td.setBlankWhenNull(true);
            detail.addElement(td);
            x += colWidth;
        }
        ((net.sf.jasperreports.engine.design.JRDesignSection) design.getDetailSection())
                .addBand(detail);

        return design;
    }

    private net.sf.jasperreports.engine.design.JRDesignParameter param(String name, Class<?> type) {
        net.sf.jasperreports.engine.design.JRDesignParameter p =
                new net.sf.jasperreports.engine.design.JRDesignParameter();
        p.setName(name);
        p.setValueClass(type);
        return p;
    }

    private JRDesignTextField staticExpr(String expression, int x, int y, int w, int h,
                                         float fontSize, boolean bold,
                                         HorizontalTextAlignEnum align) {
        JRDesignTextField tf = new JRDesignTextField();
        JRDesignExpression expr = new JRDesignExpression();
        expr.setText(expression);
        tf.setExpression(expr);
        tf.setX(x);
        tf.setY(y);
        tf.setWidth(w);
        tf.setHeight(h);
        tf.setFontSize(fontSize);
        tf.setBold(bold);
        tf.setHorizontalTextAlign(align);
        tf.setBlankWhenNull(true);
        return tf;
    }
}
