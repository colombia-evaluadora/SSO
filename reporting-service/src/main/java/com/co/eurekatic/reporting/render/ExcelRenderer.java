package com.co.eurekatic.reporting.render;

import com.co.eurekatic.reporting.config.ReportingProperties;
import org.apache.poi.ss.usermodel.Cell;
import org.apache.poi.ss.usermodel.CellStyle;
import org.apache.poi.ss.usermodel.Font;
import org.apache.poi.ss.usermodel.Row;
import org.apache.poi.ss.usermodel.Sheet;
import org.apache.poi.ss.util.WorkbookUtil;
import org.apache.poi.xssf.streaming.SXSSFSheet;
import org.apache.poi.xssf.streaming.SXSSFWorkbook;
import org.springframework.stereotype.Component;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Genera el Excel con Apache POI, no con Jasper.
 *
 * <p>Dos razones, y ninguna es de conveniencia:
 *
 * <ol>
 *   <li><b>Jasper 7 ya no trae el exportador XLSX.</b> En 6.x venia con
 *       el core; en 7.x salio y no existe un {@code jasperreports-poi}
 *       publicado para esta version (verificado contra Maven Central).</li>
 *   <li><b>Un XLSX exportado desde un JasperPrint es una foto de un
 *       documento paginado</b>, no una tabla: repite encabezados en cada
 *       corte de pagina, mete celdas combinadas y deja filas en blanco
 *       donde iban los margenes. Sirve para archivar, no para filtrar ni
 *       sumar — que es para lo que la gente pide el Excel.</li>
 * </ol>
 *
 * <p>Se usa {@code SXSSFWorkbook} (streaming): mantiene una ventana
 * chica de filas en memoria y va escribiendo el resto a disco temporal.
 * Con reportes sin tope de filas, el libro en memoria de {@code XSSF}
 * es la forma mas facil de quedarse sin heap.
 */
@Component
public class ExcelRenderer {

    /** Filas vivas en memoria antes de volcar al temporal. */
    private static final int VENTANA_FILAS = 200;

    /** Ancho aproximado de columna (POI mide en 1/256 de caracter). */
    private static final int ANCHO_COLUMNA = 22 * 256;

    public byte[] render(String clave,
                         ReportingProperties.Report def,
                         List<Map<String, Object>> rows) {

        Map<String, String> columnas = resolveColumns(def, rows);

        try (SXSSFWorkbook wb = new SXSSFWorkbook(VENTANA_FILAS);
             ByteArrayOutputStream out = new ByteArrayOutputStream()) {

            // El nombre de hoja de Excel no admite ciertos caracteres ni
            // mas de 31; WorkbookUtil deja uno valido en vez de tirar.
            String titulo = def.getTitle() == null ? clave : def.getTitle();
            SXSSFSheet sheet = wb.createSheet(WorkbookUtil.createSafeSheetName(titulo));

            CellStyle headerStyle = wb.createCellStyle();
            Font bold = wb.createFont();
            bold.setBold(true);
            headerStyle.setFont(bold);

            Row header = sheet.createRow(0);
            int c = 0;
            for (Map.Entry<String, String> e : columnas.entrySet()) {
                Cell cell = header.createCell(c);
                cell.setCellValue(e.getValue());
                cell.setCellStyle(headerStyle);
                sheet.setColumnWidth(c, ANCHO_COLUMNA);
                c++;
            }
            // Fila fija + autofiltro: es lo primero que hace cualquiera
            // que abre un export de datos, y sale gratis dejarlo puesto.
            sheet.createFreezePane(0, 1);

            int r = 1;
            for (Map<String, Object> row : rows) {
                Row fila = sheet.createRow(r++);
                int col = 0;
                for (String key : columnas.keySet()) {
                    Object raw = row.get(key);
                    Cell cell = fila.createCell(col++);
                    Double numero = CellValues.asNumber(raw);
                    if (numero != null) {
                        // Numero como numero: si va como texto, Excel no
                        // suma ni ordena bien y muestra el triangulito.
                        cell.setCellValue(numero);
                    } else {
                        cell.setCellValue(CellValues.toText(raw));
                    }
                }
            }

            // El autofiltro se aplica sobre el rango final; con 0 filas de
            // datos se omite (POI rechaza un rango invertido).
            if (r > 1) {
                sheet.setAutoFilter(new org.apache.poi.ss.util.CellRangeAddress(
                        0, r - 1, 0, Math.max(columnas.size() - 1, 0)));
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
}
