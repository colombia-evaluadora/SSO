package com.co.eurekatic.reporting.web;

import com.co.eurekatic.reporting.config.ReportingProperties;
import com.co.eurekatic.reporting.data.QueryServiceClient;
import com.co.eurekatic.reporting.render.ExcelRenderer;
import com.co.eurekatic.reporting.render.PdfRenderer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Service;
import org.springframework.web.server.ResponseStatusException;

import java.time.LocalDate;
import java.time.format.DateTimeFormatter;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * Arma un reporte: resuelve la definicion, pide las filas y las
 * convierte al formato pedido.
 */
@Service
public class ReportService {

    private static final Logger log = LoggerFactory.getLogger(ReportService.class);
    private static final DateTimeFormatter SUFIJO = DateTimeFormatter.ofPattern("yyyyMMdd");

    private final ReportingProperties props;
    private final QueryServiceClient queryService;
    private final PdfRenderer pdf;
    private final ExcelRenderer excel;

    public ReportService(ReportingProperties props,
                         QueryServiceClient queryService,
                         PdfRenderer pdf,
                         ExcelRenderer excel) {
        this.props = props;
        this.queryService = queryService;
        this.pdf = pdf;
        this.excel = excel;
    }

    /** Archivo generado, listo para responder. */
    public record Rendered(byte[] content, MediaType contentType, String fileName, int rows) {}

    public Rendered generate(String clave, ReportRequest request, String bearer) {

        ReportingProperties.Report def = props.getReports().get(clave);
        if (def == null) {
            // 404 y no 400: la clave es parte de la URL, y listar las
            // claves validas en el error le diria a cualquiera que
            // reportes existen.
            throw new ResponseStatusException(HttpStatus.NOT_FOUND,
                    "No existe el reporte '" + clave + "'.");
        }

        Formato formato = Formato.parse(request == null ? null : request.format());

        long inicio = System.currentTimeMillis();
        List<Map<String, Object>> rows = queryService.fetchRows(
                def.getPath(),
                bearer,
                request == null ? Map.of() : request.filters(),
                request == null ? null : request.sorting());

        if (rows.size() > props.getMaxRows()) {
            // Se corta ACA y no despues de generar: el archivo de un
            // resultado desmedido puede tardar minutos y ocupar cientos
            // de MB. Y se falla en vez de recortar, porque un reporte
            // truncado que no se anuncia truncado es peor que uno que no
            // sale: alguien va a tomar una decision con la mitad de los
            // datos creyendo que los tiene todos.
            throw new ResponseStatusException(HttpStatus.UNPROCESSABLE_ENTITY,
                    "El reporte devolvio " + rows.size() + " registros y el maximo es "
                    + props.getMaxRows() + ". Agrega filtros para acotarlo.");
        }

        byte[] content = switch (formato) {
            case PDF -> pdf.render(clave, def, rows);
            case EXCEL -> excel.render(clave, def, rows);
        };

        String base = def.getFileName() == null ? clave : def.getFileName();
        String nombre = base + "-" + LocalDate.now().format(SUFIJO) + formato.extension;

        log.info("Reporte '{}' generado: {} filas, {} bytes, {} ms",
                clave, rows.size(), content.length, System.currentTimeMillis() - inicio);

        return new Rendered(content, formato.mediaType, nombre, rows.size());
    }

    /** Los dos formatos que el front ya sabe pedir (`ExportFormat`). */
    private enum Formato {
        PDF(MediaType.APPLICATION_PDF, ".pdf"),
        EXCEL(MediaType.parseMediaType(
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"), ".xlsx");

        final MediaType mediaType;
        final String extension;

        Formato(MediaType mediaType, String extension) {
            this.mediaType = mediaType;
            this.extension = extension;
        }

        static Formato parse(String raw) {
            if (raw == null || raw.isBlank()) {
                return PDF;
            }
            return switch (raw.toLowerCase(Locale.ROOT)) {
                case "pdf" -> PDF;
                // "xlsx" se acepta ademas de "excel" porque es como lo
                // llama medio mundo; el front manda "excel".
                case "excel", "xlsx" -> EXCEL;
                default -> throw new ResponseStatusException(HttpStatus.BAD_REQUEST,
                        "Formato '" + raw + "' no soportado. Usa 'pdf' o 'excel'.");
            };
        }
    }
}
