package com.co.eurekatic.reporting.render;

import com.co.eurekatic.reporting.config.ReportingProperties;
import net.sf.jasperreports.engine.JRException;
import net.sf.jasperreports.engine.JasperCompileManager;
import net.sf.jasperreports.engine.JasperFillManager;
import net.sf.jasperreports.engine.JasperPrint;
import net.sf.jasperreports.engine.JasperReport;
import net.sf.jasperreports.engine.data.JRMapCollectionDataSource;
import net.sf.jasperreports.engine.design.JRDesignBand;
import net.sf.jasperreports.engine.design.JRDesignConditionalStyle;
import net.sf.jasperreports.engine.design.JRDesignExpression;
import net.sf.jasperreports.engine.design.JRDesignField;
import net.sf.jasperreports.engine.design.JRDesignLine;
import net.sf.jasperreports.engine.design.JRDesignParameter;
import net.sf.jasperreports.engine.design.JRDesignRectangle;
import net.sf.jasperreports.engine.design.JRDesignSection;
import net.sf.jasperreports.engine.design.JRDesignStaticText;
import net.sf.jasperreports.engine.design.JRDesignStyle;
import net.sf.jasperreports.engine.design.JRDesignTextField;
import net.sf.jasperreports.engine.design.JasperDesign;
import net.sf.jasperreports.engine.type.EvaluationTimeEnum;
import net.sf.jasperreports.engine.type.HorizontalTextAlignEnum;
import net.sf.jasperreports.engine.type.ModeEnum;
import net.sf.jasperreports.engine.type.OrientationEnum;
import net.sf.jasperreports.engine.type.PositionTypeEnum;
import net.sf.jasperreports.engine.type.StretchTypeEnum;
import net.sf.jasperreports.engine.type.TextAdjustEnum;
import net.sf.jasperreports.engine.type.VerticalTextAlignEnum;
import net.sf.jasperreports.engine.type.WhenNoDataTypeEnum;
import net.sf.jasperreports.export.SimpleExporterInput;
import net.sf.jasperreports.export.SimpleOutputStreamExporterOutput;
// OJO: en JasperReports 7 el exportador PDF NO esta en
// net.sf.jasperreports.engine.export (ahi vivia en 6.x): se movio al
// modulo jasperreports-pdf, bajo net.sf.jasperreports.pdf.
import net.sf.jasperreports.pdf.JRPdfExporter;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.core.io.ClassPathResource;
import org.springframework.stereotype.Component;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.time.LocalDateTime;
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
 *       plantilla — el camino para un diseño hecho en Jaspersoft Studio.</li>
 *   <li>Si no existe, se arma el diseño estándar de {@link #disenoEstandar}.</li>
 * </ol>
 *
 * <p>El segundo camino existe para que sumar un dominio no dependa de que
 * alguien abra Jaspersoft Studio: con la fila {@code query} y unas líneas de
 * YAML el reporte ya sale presentable, y el {@code .jrxml} se agrega después
 * sin tocar código. Un reporte que tarda una semana en existir porque falta el
 * diseño es un reporte que no existe.
 *
 * <p>Las plantillas compiladas se cachean por clave y ancho de columnas:
 * compilar cuesta bastante más que llenar, y el diseño solo cambia si cambian
 * las columnas.
 */
@Component
public class PdfRenderer {

    private static final Logger log = LoggerFactory.getLogger(PdfRenderer.class);

    private static final DateTimeFormatter FECHA_HORA =
            DateTimeFormatter.ofPattern("dd/MM/yyyy 'a las' HH:mm");

    private final Map<String, JasperReport> compiladas = new ConcurrentHashMap<>();

    public byte[] render(String clave,
                         ReportingProperties.Report def,
                         List<Map<String, Object>> rows,
                         ReportMeta meta) {
        try {
            Map<String, String> columnas = ColumnLayout.resolver(def, rows);
            int[] anchos = ColumnLayout.anchos(columnas, rows, usableWidth());

            // El ancho entra en la clave del cache: dos ejecuciones del mismo
            // reporte con datos distintos pueden merecer repartos distintos, y
            // reutilizar el diseño viejo dejaria las columnas mal cortadas.
            String cacheKey = clave + "#" + java.util.Arrays.toString(anchos);
            JasperReport report = compiladas.computeIfAbsent(
                    cacheKey, k -> compilar(clave, columnas, anchos));

            Map<String, Object> params = new HashMap<>();
            params.put("TITULO", def.getTitle() == null ? clave : def.getTitle());
            params.put("GENERADO", LocalDateTime.now().format(FECHA_HORA));
            params.put("TOTAL", rows.size());
            params.put("USUARIO", meta == null || meta.usuario() == null ? "" : meta.usuario());
            params.put("FILTROS", meta == null ? "" : meta.filtrosLegibles());

            JasperPrint print = JasperFillManager.fillReport(
                    report, params, new JRMapCollectionDataSource(normalizar(rows, columnas)));

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

    private static int usableWidth() {
        return ReportTheme.ANCHO_PAGINA - 2 * ReportTheme.MARGEN;
    }

    /**
     * Deja solo las columnas pedidas y aplana los valores a texto.
     *
     * <p>Aplanar es necesario: varias funciones devuelven columnas agregadas
     * como JSON (roles, sedes), y un objeto anidado impreso de una celda sale
     * como su {@code toString()} de Java. Convertirlo acá deja el mismo texto
     * en el PDF y en el Excel.
     */
    private List<Map<String, ?>> normalizar(List<Map<String, Object>> rows,
                                            Map<String, String> columnas) {
        // Bucle y no stream: el cast de Map<String,Object> a Map<String,?>
        // dentro del map() hace que se infiera List<Map<String,capture-of-?>>,
        // que no es asignable a List<Map<String,?>>.
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

    private JasperReport compilar(String clave, Map<String, String> columnas, int[] anchos) {
        try {
            ClassPathResource plantilla = new ClassPathResource("reportes/" + clave + ".jrxml");
            if (plantilla.exists()) {
                try (InputStream in = plantilla.getInputStream()) {
                    log.info("Reporte '{}': usando plantilla reportes/{}.jrxml", clave, clave);
                    return JasperCompileManager.compileReport(in);
                }
            }
            log.info("Reporte '{}': diseño estándar, {} columnas", clave, columnas.size());
            return JasperCompileManager.compileReport(disenoEstandar(columnas, anchos));
        } catch (JRException | IOException e) {
            throw new IllegalStateException(
                    "No se pudo compilar el reporte '" + clave + "'", e);
        }
    }

    /**
     * El diseño estándar: membrete, resumen de filtros, encabezados que se
     * repiten en cada página, filas con cebra y pie con paginación.
     */
    private JasperDesign disenoEstandar(Map<String, String> columnas, int[] anchos)
            throws JRException {

        JasperDesign d = new JasperDesign();
        d.setName("reporte");
        d.setPageWidth(ReportTheme.ANCHO_PAGINA);
        d.setPageHeight(ReportTheme.ALTO_PAGINA);
        d.setOrientation(OrientationEnum.LANDSCAPE);
        d.setLeftMargin(ReportTheme.MARGEN);
        d.setRightMargin(ReportTheme.MARGEN);
        d.setTopMargin(ReportTheme.MARGEN);
        d.setBottomMargin(ReportTheme.MARGEN);
        d.setColumnWidth(usableWidth());
        // Sin esto, un reporte cuyo filtro no encontró nada sale como un
        // archivo de cero páginas, que el visor abre como "corrupto". Con
        // NO_DATA_SECTION se imprime la banda de abajo y queda claro que la
        // consulta corrió y no hubo resultados.
        d.setWhenNoDataType(WhenNoDataTypeEnum.NO_DATA_SECTION);

        for (String p : List.of("TITULO", "GENERADO", "USUARIO", "FILTROS")) {
            d.addParameter(parametro(p, String.class));
        }
        d.addParameter(parametro("TOTAL", Integer.class));

        for (String col : columnas.keySet()) {
            JRDesignField f = new JRDesignField();
            f.setName(col);
            f.setValueClass(String.class);
            d.addField(f);
        }

        // El estilo por defecto fija la familia embebida. Marcarlo default
        // hace que lo hereden todos los elementos de texto, sin repetir
        // setFontName() en cada uno.
        JRDesignStyle base = new JRDesignStyle();
        base.setName("base");
        base.setDefault(true);
        base.setFontName(ReportTheme.FUENTE);
        d.addStyle(base);

        JRDesignStyle filaStyle = estiloFilaConCebra();
        d.addStyle(filaStyle);

        int ancho = usableWidth();
        d.setTitle(bandaTitulo(ancho));
        d.setPageHeader(bandaFiltros(ancho));
        d.setColumnHeader(bandaEncabezados(columnas, anchos));
        ((JRDesignSection) d.getDetailSection()).addBand(bandaDetalle(columnas, anchos, filaStyle));
        d.setPageFooter(bandaPie(ancho));
        d.setNoData(bandaSinDatos(ancho));

        return d;
    }

    /** Membrete: título, línea de contexto y la regla del acento. */
    private JRDesignBand bandaTitulo(int ancho) {
        JRDesignBand banda = new JRDesignBand();
        banda.setHeight(52);

        JRDesignTextField titulo = campoExpr("$P{TITULO}", 0, 0, ancho, 20,
                ReportTheme.TAM_TITULO, true, HorizontalTextAlignEnum.LEFT);
        titulo.setForecolor(ReportTheme.TINTA_FUERTE);
        banda.addElement(titulo);

        // Fecha, total y autor en una sola línea: es el mínimo que necesita
        // alguien que recibe el PDF suelto para saber qué está mirando.
        JRDesignTextField contexto = campoExpr(
                "\"Generado el \" + $P{GENERADO} + \"   ·   \" + $P{TOTAL} + \" registro(s)\""
                        + " + ($P{USUARIO}.isEmpty() ? \"\" : \"   ·   por \" + $P{USUARIO})",
                0, 22, ancho, 12,
                ReportTheme.TAM_SUBTITULO, false, HorizontalTextAlignEnum.LEFT);
        contexto.setForecolor(ReportTheme.TINTA_SUAVE);
        banda.addElement(contexto);

        JRDesignLine regla = new JRDesignLine();
        regla.setX(0);
        regla.setY(44);
        regla.setWidth(ancho);
        regla.setHeight(1);
        regla.getLinePen().setLineWidth(1.5f);
        regla.getLinePen().setLineColor(ReportTheme.ACENTO);
        banda.addElement(regla);

        return banda;
    }

    /**
     * Los filtros aplicados. La banda se auto-colapsa cuando no hay ninguno:
     * `removeLineWhenBlank` sobre el campo más `setHeight` chico deja el
     * espacio en cero en vez de un hueco vacío arriba de la tabla.
     */
    private JRDesignBand bandaFiltros(int ancho) {
        JRDesignBand banda = new JRDesignBand();
        banda.setHeight(14);

        JRDesignTextField filtros = campoExpr(
                "$P{FILTROS}.isEmpty() ? null : \"Filtros aplicados —  \" + $P{FILTROS}",
                0, 2, ancho, 10,
                ReportTheme.TAM_PIE, false, HorizontalTextAlignEnum.LEFT);
        filtros.setForecolor(ReportTheme.TINTA_SUAVE);
        filtros.setItalic(true);
        filtros.setBlankWhenNull(true);
        filtros.setRemoveLineWhenBlank(true);
        banda.addElement(filtros);

        return banda;
    }

    /** Encabezados de columna, con fondo y regla inferior. Se repiten por página. */
    private JRDesignBand bandaEncabezados(Map<String, String> columnas, int[] anchos) {
        JRDesignBand banda = new JRDesignBand();
        banda.setHeight(ReportTheme.ALTO_ENCABEZADO + 3);

        JRDesignRectangle fondo = new JRDesignRectangle();
        fondo.setX(0);
        fondo.setY(0);
        fondo.setWidth(sumar(anchos));
        fondo.setHeight(ReportTheme.ALTO_ENCABEZADO);
        fondo.setBackcolor(ReportTheme.FONDO_ENCABEZADO);
        fondo.setMode(ModeEnum.OPAQUE);
        // Sin borde propio: el rectángulo aporta el fondo y la regla de abajo
        // la dibuja la línea, que no queda cortada entre columnas.
        fondo.getLinePen().setLineWidth(0f);
        banda.addElement(fondo);

        int x = 0;
        int i = 0;
        for (Map.Entry<String, String> e : columnas.entrySet()) {
            JRDesignStaticText th = new JRDesignStaticText();
            th.setText(e.getValue());
            th.setX(x + ReportTheme.PADDING_CELDA);
            th.setY(0);
            th.setWidth(anchos[i] - 2 * ReportTheme.PADDING_CELDA);
            th.setHeight(ReportTheme.ALTO_ENCABEZADO);
            th.setFontSize(ReportTheme.TAM_ENCABEZADO);
            th.setBold(true);
            th.setForecolor(ReportTheme.TINTA_FUERTE);
            th.setVerticalTextAlign(VerticalTextAlignEnum.MIDDLE);
            banda.addElement(th);
            x += anchos[i];
            i++;
        }

        JRDesignLine regla = new JRDesignLine();
        regla.setX(0);
        regla.setY(ReportTheme.ALTO_ENCABEZADO);
        regla.setWidth(sumar(anchos));
        regla.setHeight(1);
        regla.getLinePen().setLineWidth(1f);
        regla.getLinePen().setLineColor(ReportTheme.ACENTO);
        banda.addElement(regla);

        return banda;
    }

    private JRDesignBand bandaDetalle(Map<String, String> columnas, int[] anchos,
                                      JRDesignStyle filaStyle) {
        JRDesignBand banda = new JRDesignBand();
        // +1 para que entre el separador de abajo: Jasper valida que ningún
        // elemento sobresalga de su banda, y una línea en y=ALTO_FILA dentro
        // de una banda de ALTO_FILA la rebasa por un punto.
        banda.setHeight(ReportTheme.ALTO_FILA + 1);

        // El fondo cebra es un rectángulo del ancho de la fila con el estilo
        // condicional: pintar cada celda por separado dejaría costuras
        // blancas entre columnas cuando el texto no llena la celda.
        JRDesignRectangle fondo = new JRDesignRectangle();
        fondo.setX(0);
        fondo.setY(0);
        fondo.setWidth(sumar(anchos));
        fondo.setHeight(ReportTheme.ALTO_FILA);
        fondo.setStyle(filaStyle);
        fondo.getLinePen().setLineWidth(0f);
        // Crece hasta el alto final de la banda: sin esto, una fila que se
        // estira a dos lineas queda con la mitad de abajo sin fondo.
        // (En Jasper 7 RELATIVE_TO_TALLEST_OBJECT se renombro a
        // ELEMENT_GROUP_HEIGHT y RELATIVE_TO_BAND_HEIGHT a CONTAINER_HEIGHT;
        // acá el contenedor ES la fila, así que va CONTAINER_HEIGHT.)
        fondo.setStretchType(StretchTypeEnum.CONTAINER_HEIGHT);
        banda.addElement(fondo);

        int x = 0;
        int i = 0;
        for (String col : columnas.keySet()) {
            JRDesignTextField td = campoExpr("$F{" + col + "}",
                    x + ReportTheme.PADDING_CELDA, 0,
                    anchos[i] - 2 * ReportTheme.PADDING_CELDA, ReportTheme.ALTO_FILA,
                    ReportTheme.TAM_CUERPO, false, HorizontalTextAlignEnum.LEFT);
            td.setForecolor(ReportTheme.TINTA);
            td.setVerticalTextAlign(VerticalTextAlignEnum.MIDDLE);
            // Un nombre largo no debe empujar la columna siguiente ni
            // desaparecer: se estira la fila.
            td.setTextAdjust(TextAdjustEnum.STRETCH_HEIGHT);
            td.setBlankWhenNull(true);
            banda.addElement(td);
            x += anchos[i];
            i++;
        }

        JRDesignLine separador = new JRDesignLine();
        separador.setX(0);
        separador.setY(ReportTheme.ALTO_FILA);
        // FLOAT: el separador baja cuando la fila se estira. Con la posicion
        // fija se quedaba en y=15 y le cortaba la segunda linea al texto.
        separador.setPositionType(PositionTypeEnum.FLOAT);
        separador.setWidth(sumar(anchos));
        separador.setHeight(1);
        separador.getLinePen().setLineWidth(0.5f);
        separador.getLinePen().setLineColor(ReportTheme.LINEA);
        banda.addElement(separador);

        return banda;
    }

    private JRDesignBand bandaPie(int ancho) {
        JRDesignBand banda = new JRDesignBand();
        banda.setHeight(22);

        JRDesignLine regla = new JRDesignLine();
        regla.setX(0);
        regla.setY(2);
        regla.setWidth(ancho);
        regla.setHeight(1);
        regla.getLinePen().setLineWidth(0.5f);
        regla.getLinePen().setLineColor(ReportTheme.LINEA);
        banda.addElement(regla);

        JRDesignTextField origen = campoExpr(
                "\"Colombia Evaluadora  ·  documento generado automáticamente\"",
                0, 7, ancho / 2, 10,
                ReportTheme.TAM_PIE, false, HorizontalTextAlignEnum.LEFT);
        origen.setForecolor(ReportTheme.TINTA_SUAVE);
        banda.addElement(origen);

        // "Página X de Y" necesita DOS campos: el total de páginas solo se
        // conoce al terminar el reporte, así que ese va con evaluationTime
        // REPORT. Con un solo campo evaluado al vuelo, "de Y" imprimiría el
        // número de la página actual.
        JRDesignTextField pagina = campoExpr(
                "\"Página \" + $V{PAGE_NUMBER} + \" de \"",
                ancho / 2, 7, ancho / 2 - 43, 10,
                ReportTheme.TAM_PIE, false, HorizontalTextAlignEnum.RIGHT);
        pagina.setForecolor(ReportTheme.TINTA_SUAVE);
        banda.addElement(pagina);

        // Arranca 6pt despues de donde termina el campo anterior: pegados,
        // el espacio final de "de " se recorta al renderizar y sale "de2".
        JRDesignTextField total = campoExpr("$V{PAGE_NUMBER}",
                ancho - 40, 7, 40, 10,
                ReportTheme.TAM_PIE, false, HorizontalTextAlignEnum.LEFT);
        total.setForecolor(ReportTheme.TINTA_SUAVE);
        total.setEvaluationTime(EvaluationTimeEnum.REPORT);
        banda.addElement(total);

        return banda;
    }

    private JRDesignBand bandaSinDatos(int ancho) {
        JRDesignBand banda = new JRDesignBand();
        banda.setHeight(90);

        JRDesignTextField titulo = campoExpr("$P{TITULO}", 0, 0, ancho, 20,
                ReportTheme.TAM_TITULO, true, HorizontalTextAlignEnum.LEFT);
        titulo.setForecolor(ReportTheme.TINTA_FUERTE);
        banda.addElement(titulo);

        JRDesignTextField contexto = campoExpr(
                "\"Generado el \" + $P{GENERADO}"
                        + " + ($P{FILTROS}.isEmpty() ? \"\" : \"   ·   \" + $P{FILTROS})",
                0, 22, ancho, 12,
                ReportTheme.TAM_SUBTITULO, false, HorizontalTextAlignEnum.LEFT);
        contexto.setForecolor(ReportTheme.TINTA_SUAVE);
        banda.addElement(contexto);

        JRDesignLine regla = new JRDesignLine();
        regla.setX(0);
        regla.setY(44);
        regla.setWidth(ancho);
        regla.setHeight(1);
        regla.getLinePen().setLineWidth(1.5f);
        regla.getLinePen().setLineColor(ReportTheme.ACENTO);
        banda.addElement(regla);

        JRDesignStaticText aviso = new JRDesignStaticText();
        aviso.setText("No hay registros que coincidan con los filtros aplicados.");
        aviso.setX(0);
        aviso.setY(62);
        aviso.setWidth(ancho);
        aviso.setHeight(14);
        aviso.setFontSize(ReportTheme.TAM_CUERPO);
        aviso.setForecolor(ReportTheme.TINTA_SUAVE);
        aviso.setHorizontalTextAlign(HorizontalTextAlignEnum.CENTER);
        banda.addElement(aviso);

        return banda;
    }

    /**
     * Estilo transparente por defecto con una variante opaca en las filas
     * pares. {@code REPORT_COUNT} es la variable interna con el número de fila
     * ya procesada, así que sirve de índice sin declarar una propia.
     */
    private JRDesignStyle estiloFilaConCebra() {
        JRDesignStyle base = new JRDesignStyle();
        base.setName("fila");
        base.setMode(ModeEnum.TRANSPARENT);

        JRDesignConditionalStyle par = new JRDesignConditionalStyle();
        JRDesignExpression cond = new JRDesignExpression();
        cond.setText("$V{REPORT_COUNT}.intValue() % 2 == 0");
        par.setConditionExpression(cond);
        par.setMode(ModeEnum.OPAQUE);
        par.setBackcolor(ReportTheme.FONDO_CEBRA);
        base.addConditionalStyle(par);

        return base;
    }

    private static int sumar(int[] valores) {
        int total = 0;
        for (int v : valores) total += v;
        return total;
    }

    private JRDesignParameter parametro(String nombre, Class<?> tipo) {
        JRDesignParameter p = new JRDesignParameter();
        p.setName(nombre);
        p.setValueClass(tipo);
        return p;
    }

    private JRDesignTextField campoExpr(String expresion, int x, int y, int w, int h,
                                        float tam, boolean negrita,
                                        HorizontalTextAlignEnum alineacion) {
        JRDesignTextField tf = new JRDesignTextField();
        JRDesignExpression expr = new JRDesignExpression();
        expr.setText(expresion);
        tf.setExpression(expr);
        tf.setX(x);
        tf.setY(y);
        tf.setWidth(w);
        tf.setHeight(h);
        tf.setFontSize(tam);
        tf.setBold(negrita);
        tf.setHorizontalTextAlign(alineacion);
        tf.setBlankWhenNull(true);
        return tf;
    }
}
