package com.co.eurekatic.reporting.render;

import com.co.eurekatic.reporting.config.ReportingProperties;
import org.apache.poi.ss.usermodel.BorderStyle;
import org.apache.poi.ss.usermodel.Cell;
import org.apache.poi.ss.usermodel.CellStyle;
import org.apache.poi.ss.usermodel.FillPatternType;
import org.apache.poi.ss.usermodel.Font;
import org.apache.poi.ss.usermodel.HorizontalAlignment;
import org.apache.poi.ss.usermodel.Row;
import org.apache.poi.ss.usermodel.VerticalAlignment;
import org.apache.poi.ss.util.CellRangeAddress;
import org.apache.poi.ss.util.WorkbookUtil;
import org.apache.poi.xssf.streaming.SXSSFSheet;
import org.apache.poi.xssf.streaming.SXSSFWorkbook;
import org.apache.poi.xssf.usermodel.XSSFColor;
import org.apache.poi.xssf.usermodel.XSSFCellStyle;
import org.apache.poi.xssf.usermodel.XSSFFont;
import org.springframework.stereotype.Component;

import java.awt.Color;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.List;
import java.util.Map;

/**
 * Genera el Excel con Apache POI, no con Jasper.
 *
 * <p>Dos razones, y ninguna es de conveniencia:
 *
 * <ol>
 *   <li><b>Jasper 7 ya no trae el exportador XLSX.</b> En 6.x venía con el
 *       core; en 7.x salió y no existe un {@code jasperreports-poi} publicado
 *       para esta versión (verificado contra Maven Central).</li>
 *   <li><b>Un XLSX exportado desde un JasperPrint es una foto de un documento
 *       paginado</b>, no una tabla: repite encabezados en cada corte de
 *       página, mete celdas combinadas y deja filas en blanco donde iban los
 *       márgenes. Sirve para archivar, no para filtrar ni sumar — que es para
 *       lo que la gente pide el Excel.</li>
 * </ol>
 *
 * <p>De ahí el criterio de diseño: el PDF es un <em>documento</em> y el Excel
 * es una <em>herramienta</em>. Comparten identidad (mismos colores, mismo
 * encabezado) pero no forma — acá el membrete es de tres filas y no se repite,
 * la fila de títulos queda congelada y con autofiltro, y no hay cebra, porque
 * el rayado propio de Excel ya cumple esa función y encima estorba al ordenar.
 *
 * <p>Se usa {@code SXSSFWorkbook} (streaming): mantiene una ventana chica de
 * filas en memoria y va escribiendo el resto a disco temporal. Con reportes
 * sin tope de filas, el libro en memoria de {@code XSSF} es la forma más fácil
 * de quedarse sin heap.
 */
@Component
public class ExcelRenderer {

    /** Filas vivas en memoria antes de volcar al temporal. */
    private static final int VENTANA_FILAS = 200;

    private static final DateTimeFormatter FECHA_HORA =
            DateTimeFormatter.ofPattern("dd/MM/yyyy HH:mm");

    /** Ancho de columna en unidades POI (1/256 de carácter). */
    private static final int UNIDAD = 256;

    /** Filas de membrete antes de los encabezados. */
    private static final int FILA_TITULO = 0;
    private static final int FILA_CONTEXTO = 1;
    private static final int FILA_FILTROS = 2;
    private static final int FILA_ENCABEZADOS = 4;

    public byte[] render(String clave,
                         ReportingProperties.Report def,
                         List<Map<String, Object>> rows,
                         ReportMeta meta) {

        Map<String, String> columnas = ColumnLayout.resolver(def, rows);
        String titulo = def == null || def.getTitle() == null ? clave : def.getTitle();

        try (SXSSFWorkbook wb = new SXSSFWorkbook(VENTANA_FILAS);
             ByteArrayOutputStream out = new ByteArrayOutputStream()) {

            // El nombre de hoja de Excel no admite ciertos caracteres ni más de
            // 31; WorkbookUtil deja uno válido en vez de tirar.
            SXSSFSheet hoja = wb.createSheet(WorkbookUtil.createSafeSheetName(titulo));

            CellStyle estiloTitulo = estiloTitulo(wb);
            CellStyle estiloMeta = estiloMeta(wb);
            CellStyle estiloEncabezado = estiloEncabezado(wb);

            int ultimaColumna = Math.max(columnas.size() - 1, 0);

            escribirTexto(hoja, FILA_TITULO, titulo, estiloTitulo, ultimaColumna);

            String contexto = "Generado el " + LocalDateTime.now().format(FECHA_HORA)
                    + "   ·   " + rows.size() + " registro(s)"
                    + (meta != null && meta.usuario() != null && !meta.usuario().isBlank()
                       ? "   ·   por " + meta.usuario() : "");
            escribirTexto(hoja, FILA_CONTEXTO, contexto, estiloMeta, ultimaColumna);

            // Igual que en el PDF: el archivo tiene que poder interpretarse
            // solo, sin la pantalla donde se generó.
            String filtros = meta == null ? "" : meta.filtrosLegibles();
            escribirTexto(hoja, FILA_FILTROS,
                    filtros.isEmpty() ? "Sin filtros aplicados" : "Filtros aplicados —  " + filtros,
                    estiloMeta, ultimaColumna);

            Row encabezados = hoja.createRow(FILA_ENCABEZADOS);
            encabezados.setHeightInPoints(18f);
            int c = 0;
            for (Map.Entry<String, String> e : columnas.entrySet()) {
                Cell celda = encabezados.createCell(c);
                celda.setCellValue(e.getValue());
                celda.setCellStyle(estiloEncabezado);
                c++;
            }

            int r = FILA_ENCABEZADOS + 1;
            for (Map<String, Object> row : rows) {
                Row fila = hoja.createRow(r++);
                int col = 0;
                for (String key : columnas.keySet()) {
                    Object crudo = row.get(key);
                    Cell celda = fila.createCell(col++);
                    Double numero = CellValues.asNumber(crudo);
                    if (numero != null) {
                        // Número como número: si va como texto, Excel no suma
                        // ni ordena bien y muestra el triangulito de aviso.
                        celda.setCellValue(numero);
                    } else {
                        celda.setCellValue(CellValues.toText(crudo));
                    }
                }
            }

            aplicarAnchos(hoja, columnas, rows);

            // Congelar debajo del encabezado y dejar el autofiltro puesto: es
            // lo primero que hace cualquiera que abre un export de datos.
            hoja.createFreezePane(0, FILA_ENCABEZADOS + 1);
            if (r > FILA_ENCABEZADOS + 1) {
                // Con cero filas de datos el rango quedaría invertido y POI lo
                // rechaza, así que el autofiltro se omite.
                hoja.setAutoFilter(new CellRangeAddress(
                        FILA_ENCABEZADOS, r - 1, 0, ultimaColumna));
            }

            wb.write(out);
            // Borra los temporales del streaming; sin esto quedan en /tmp
            // hasta que muera el proceso.
            wb.dispose();
            return out.toByteArray();

        } catch (IOException e) {
            throw new IllegalStateException(
                    "No se pudo generar el Excel del reporte '" + clave + "'", e);
        }
    }

    /** Texto de membrete combinado a lo ancho de la tabla. */
    private void escribirTexto(SXSSFSheet hoja, int fila, String texto,
                               CellStyle estilo, int ultimaColumna) {
        Row row = hoja.createRow(fila);
        Cell celda = row.createCell(0);
        celda.setCellValue(texto);
        celda.setCellStyle(estilo);
        if (ultimaColumna > 0) {
            hoja.addMergedRegion(new CellRangeAddress(fila, fila, 0, ultimaColumna));
        }
    }

    /**
     * Mismo cálculo de ancho que el PDF, traducido a las unidades de POI: se
     * mide el contenido real en vez de dejar todas las columnas iguales.
     */
    private void aplicarAnchos(SXSSFSheet hoja, Map<String, String> columnas,
                               List<Map<String, Object>> rows) {
        // Se reparte sobre una "página" nominal de 1400 puntos para reusar el
        // mismo reparto proporcional; después se convierte a caracteres. No se
        // usa autoSizeColumn porque en SXSSF solo ve las filas de la ventana
        // en memoria, no el resto — daría anchos calculados sobre 200 filas.
        int[] puntos = ColumnLayout.anchos(columnas, rows, 1400);
        for (int i = 0; i < puntos.length; i++) {
            // ~5.5 puntos por carácter a 8pt; el +2 es el aire del autofiltro.
            int caracteres = (int) Math.round(puntos[i] / 5.5) + 2;
            hoja.setColumnWidth(i, Math.min(Math.max(caracteres, 10), 60) * UNIDAD);
        }
    }

    private CellStyle estiloTitulo(SXSSFWorkbook wb) {
        XSSFFont fuente = (XSSFFont) wb.createFont();
        fuente.setBold(true);
        fuente.setFontHeightInPoints((short) 14);
        fuente.setColor(color(ReportTheme.TINTA_FUERTE));

        XSSFCellStyle estilo = (XSSFCellStyle) wb.createCellStyle();
        estilo.setFont(fuente);
        estilo.setVerticalAlignment(VerticalAlignment.CENTER);
        return estilo;
    }

    private CellStyle estiloMeta(SXSSFWorkbook wb) {
        XSSFFont fuente = (XSSFFont) wb.createFont();
        fuente.setFontHeightInPoints((short) 9);
        fuente.setColor(color(ReportTheme.TINTA_SUAVE));

        XSSFCellStyle estilo = (XSSFCellStyle) wb.createCellStyle();
        estilo.setFont(fuente);
        return estilo;
    }

    private CellStyle estiloEncabezado(SXSSFWorkbook wb) {
        XSSFFont fuente = (XSSFFont) wb.createFont();
        fuente.setBold(true);
        fuente.setFontHeightInPoints((short) 10);
        fuente.setColor(color(ReportTheme.TINTA_FUERTE));

        XSSFCellStyle estilo = (XSSFCellStyle) wb.createCellStyle();
        estilo.setFont(fuente);
        estilo.setFillForegroundColor(color(ReportTheme.FONDO_ENCABEZADO));
        estilo.setFillPattern(FillPatternType.SOLID_FOREGROUND);
        estilo.setBorderBottom(BorderStyle.MEDIUM);
        estilo.setBottomBorderColor(color(ReportTheme.ACENTO));
        estilo.setAlignment(HorizontalAlignment.LEFT);
        estilo.setVerticalAlignment(VerticalAlignment.CENTER);
        return estilo;
    }

    /** Los colores del tema (java.awt) al tipo que espera POI. */
    private XSSFColor color(Color c) {
        return new XSSFColor(new byte[]{
                (byte) c.getRed(), (byte) c.getGreen(), (byte) c.getBlue()}, null);
    }
}
