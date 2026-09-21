package com.co.eurekatic.reporting.web;

import com.co.eurekatic.reporting.config.ReportingProperties;
import com.co.eurekatic.reporting.data.FileServiceClient;
import com.co.eurekatic.reporting.data.QueryServiceClient;
import com.co.eurekatic.reporting.render.ExcelRenderer;
import com.co.eurekatic.reporting.render.Fechas;
import com.co.eurekatic.reporting.render.ReportMeta;
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
    private final FileServiceClient fileService;
    private final PdfRenderer pdf;
    private final ExcelRenderer excel;

    public ReportService(ReportingProperties props,
                         QueryServiceClient queryService,
                         FileServiceClient fileService,
                         PdfRenderer pdf,
                         ExcelRenderer excel) {
        this.props = props;
        this.queryService = queryService;
        this.fileService = fileService;
        this.pdf = pdf;
        this.excel = excel;
    }

    /** Archivo generado, listo para responder. */
    public record Rendered(byte[] content, MediaType contentType, String fileName, int rows) {}

    public Rendered generate(String clave, ReportRequest request, String bearer,
                             String usuario) {

        ReportingProperties.Report def = props.getReports().get(clave);
        if (def == null) {
            // 404 y no 400: la clave es parte de la URL, y listar las
            // claves validas en el error le diria a cualquiera que
            // reportes existen.
            throw new ResponseStatusException(HttpStatus.NOT_FOUND,
                    "No existe el reporte '" + clave + "'.");
        }

        Formato formato = Formato.parse(request == null ? null : request.format());

        // Un reporte puede declarar que no todos los formatos le aplican. Un
        // boletin en Excel seria una fila ilegible por estudiante: mejor un
        // 400 que diga por que, que un archivo que nadie puede usar.
        List<String> admitidos = def.getFormats();
        if (admitidos != null && !admitidos.isEmpty()
                && admitidos.stream().noneMatch(f -> f.equalsIgnoreCase(formato.name()))) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST,
                    "El reporte '" + clave + "' no se puede exportar en "
                    + formato.name().toLowerCase(Locale.ROOT)
                    + ". Formatos disponibles: " + String.join(", ", admitidos) + ".");
        }

        long inicio = System.currentTimeMillis();
        List<Map<String, Object>> rows = queryService.fetchRows(
                def.getBaseUrl(),
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

        // El reporte lleva impreso con que filtros salio: un PDF exportado
        // circula por correo y sobrevive al contexto donde se genero, asi que
        // sin esa linea nadie puede distinguir "el padron completo" de "los
        // de una sola sede".
        ReportMeta meta = new ReportMeta(usuario, request == null ? null : request.filters());

        List<String> columnas = request == null ? null : request.columns();
        // La sesion de descargas vive lo que vive el reporte: los bytes de las
        // imagenes se sueltan con el, no se quedan en el proceso.
        FileServiceClient.Sesion imagenes =
                def.getImageFields() == null || def.getImageFields().isEmpty()
                        ? null
                        : fileService.nuevaSesion();
        byte[] content = switch (formato) {
            case PDF -> pdf.render(clave, def, rows, meta, columnas, imagenes);
            case EXCEL -> excel.render(clave, def, rows, meta, columnas);
        };

        String base = def.getFileName() == null ? clave : def.getFileName();
        // En hora de Colombia, no del JVM: un reporte pedido a las 8 de la
        // noche en Bogota son las 01:00 UTC del dia siguiente, y el archivo
        // saldria fechado manana.
        String nombre = base + "-" + Fechas.ahora().format(SUFIJO) + formato.extension;

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
