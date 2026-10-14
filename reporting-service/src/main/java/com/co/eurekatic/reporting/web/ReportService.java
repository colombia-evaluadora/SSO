package com.co.eurekatic.reporting.web;

import com.co.eurekatic.reporting.config.ReportingProperties;
import com.co.eurekatic.reporting.data.FileServiceClient;
import com.co.eurekatic.reporting.data.QueryServiceClient;
import com.co.eurekatic.reporting.render.ExcelRenderer;
import com.co.eurekatic.reporting.render.Fechas;
import com.co.eurekatic.reporting.render.ReportMeta;
import com.co.eurekatic.reporting.render.PdfRenderer;
import com.co.eurekatic.reporting.verificacion.EmisionBoletines;
import org.springframework.beans.factory.annotation.Autowired;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Service;
import org.springframework.web.server.ResponseStatusException;

import java.time.LocalDate;
import java.time.format.DateTimeFormatter;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;

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
    /** Limita las exportaciones en vuelo de esta instancia (memoria). */
    private final Semaphore permisos;
    /** Registra el boletin impreso y le pone el QR; null = sin verificacion. */
    private final EmisionBoletines emisiones;

    public ReportService(ReportingProperties props,
                         QueryServiceClient queryService,
                         FileServiceClient fileService,
                         PdfRenderer pdf,
                         ExcelRenderer excel) {
        this(props, queryService, fileService, pdf, excel, null);
    }

    @Autowired
    public ReportService(ReportingProperties props,
                         QueryServiceClient queryService,
                         FileServiceClient fileService,
                         PdfRenderer pdf,
                         ExcelRenderer excel,
                         EmisionBoletines emisiones) {
        this.props = props;
        this.queryService = queryService;
        this.fileService = fileService;
        this.pdf = pdf;
        this.excel = excel;
        this.emisiones = emisiones;
        this.permisos = new Semaphore(Math.max(1, props.getMaxConcurrentExports()));
    }

    /**
     * Arma el PDF de un boletin con filas ya obtenidas (la copia publica de
     * verificacion), bajo el mismo tope de exportaciones simultaneas.
     */
    public byte[] renderBoletin(String variante, List<Map<String, Object>> rows,
                                Map<String, Object> extra) {
        ReportingProperties.Report def = props.getReports().get(variante);
        if (def == null) {
            throw new IllegalStateException("La variante '" + variante + "' no esta configurada.");
        }
        adquirir();
        try {
            FileServiceClient.Sesion imagenes =
                    def.getImageFields() == null || def.getImageFields().isEmpty()
                            ? null
                            : fileService.nuevaSesion();
            return pdf.render(variante, def, rows, null, null, imagenes, extra);
        } finally {
            permisos.release();
        }
    }

    /** 429 con Retry-After: el cliente puede reintentar en unos segundos. */
    private static final class Saturado extends ResponseStatusException {
        Saturado() {
            super(HttpStatus.TOO_MANY_REQUESTS,
                    "Hay demasiadas exportaciones en curso. Intenta de nuevo en unos segundos.");
        }

        @Override
        public HttpHeaders getHeaders() {
            HttpHeaders h = new HttpHeaders();
            h.set(HttpHeaders.RETRY_AFTER, "5");
            return h;
        }
    }

    private void adquirir() {
        try {
            if (!permisos.tryAcquire(props.getExportAcquireTimeout().toMillis(), TimeUnit.MILLISECONDS)) {
                throw new Saturado();
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new Saturado();
        }
    }

    /**
     * La clave del reporte que atiende la variante pedida. Aqui si se listan
     * los valores validos: el reporte ya se sabe que existe y el front
     * necesita saber que mandar.
     */
    private static String variante(String clave, ReportingProperties.Report def,
                                   Map<String, String> query) {
        String param = def.getVariantParam();
        String valor = query == null || param == null ? null : query.get(param);
        String destino = valor == null ? null : def.getVariants().get(valor.trim().toLowerCase(Locale.ROOT));
        if (destino == null) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST,
                    "El reporte '" + clave + "' necesita el parametro '" + param + "' con uno de: "
                    + String.join(", ", def.getVariants().keySet()) + ".");
        }
        return destino;
    }

    /** Archivo generado, listo para responder. */
    public record Rendered(byte[] content, MediaType contentType, String fileName, int rows) {}

    public Rendered generate(String clave, ReportRequest request, String bearer,
                             String usuario) {
        return generate(clave, Map.of(), request, bearer, usuario);
    }

    /** @param query los query params de la peticion; eligen la variante del reporte. */
    public Rendered generate(String clave, Map<String, String> query, ReportRequest request,
                             String bearer, String usuario) {

        ReportingProperties.Report def = props.getReports().get(clave);
        if (def == null) {
            // 404 y no 400: la clave es parte de la URL, y listar las
            // claves validas en el error le diria a cualquiera que
            // reportes existen.
            throw new ResponseStatusException(HttpStatus.NOT_FOUND,
                    "No existe el reporte '" + clave + "'.");
        }
        // El boletin (la clave que agrupa sus variantes) es el unico que lleva
        // QR de verificacion; el nivel pedido es el que se registra.
        String nivelBoletin = null;
        if (props.getVerificacion() != null
                && clave.equals(props.getVerificacion().getReporte())
                && def.getVariantParam() != null && query != null) {
            String n = query.get(def.getVariantParam());
            nivelBoletin = n == null ? null : n.trim().toLowerCase(Locale.ROOT);
        }
        if (def.getVariants() != null && !def.getVariants().isEmpty()) {
            clave = variante(clave, def, query);
            def = props.getReports().get(clave);
            if (def == null) {
                throw new IllegalStateException("La variante '" + clave + "' no esta configurada.");
            }
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

        adquirir();
        try {
            return generar(clave, def, formato, request, bearer, usuario, nivelBoletin);
        } finally {
            permisos.release();
        }
    }

    private Rendered generar(String clave, ReportingProperties.Report def, Formato formato,
                             ReportRequest request, String bearer, String usuario,
                             String nivelBoletin) {
        long inicio = System.currentTimeMillis();
        List<Map<String, Object>> rows = queryService.fetchRows(
                def.getBaseUrl(),
                def.getPath(),
                bearer,
                request == null ? Map.of() : request.filters(),
                request == null ? null : request.sorting(),
                props.getMaxRows());

        // Red de seguridad: el cliente ya corta en streaming al superar el tope.
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

        if (nivelBoletin != null && emisiones != null) {
            rows = emisiones.marcar(nivelBoletin,
                    request == null ? Map.of() : request.filters(), rows, bearer);
        }

        // El reporte lleva impreso con que filtros salio: un PDF exportado
        // circula por correo y sobrevive al contexto donde se genero, asi que
        // sin esa linea nadie puede distinguir "el padron completo" de "los
        // de una sola sede".
        ReportMeta meta = new ReportMeta(
                usuario,
                request == null ? null : request.filters(),
                request == null ? null : request.filtersLabel());

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
