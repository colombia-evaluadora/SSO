package com.co.eurekatic.reporting.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Configuracion del servicio, bajo el prefijo {@code reporting}.
 *
 * <p>El catalogo de reportes es configuracion, no codigo: agregar un
 * reporte nuevo es agregar una entrada en {@code application.yml} y,
 * si se quiere un diseno propio, dejar un {@code .jrxml} en
 * {@code classpath:reportes/}. No hay que tocar Java ni recompilar
 * para sumar un dominio.
 */
@ConfigurationProperties(prefix = "reporting")
public class ReportingProperties {

    /**
     * Base del query-service. En docker apunta directo al servicio
     * (no al gateway): el reporting-service ya esta dentro de la red
     * y dar la vuelta por el gateway solo agrega un salto y un punto
     * de falla mas.
     */
    private String queryServiceBaseUrl;

    /**
     * Tope duro de filas por reporte. Quitar el LIMIT de las funciones
     * (V66) quito tambien la red de contencion: sin esto, un filtro mal
     * puesto sobre una tabla de cientos de miles de filas no produce un
     * reporte, produce un incidente. Al superarlo se responde 422 con un
     * mensaje que dice que hay que filtrar mas — no se recorta el
     * resultado en silencio, porque un reporte incompleto que parece
     * completo es peor que ninguno.
     */
    private int maxRows = 50_000;

    /** Timeout de la llamada al query-service. Un reporte sin paginar
     *  tarda mucho mas que un listado de 10 filas. */
    private java.time.Duration requestTimeout = java.time.Duration.ofMinutes(3);

    /**
     * Base de file-service, de donde se bajan las imagenes que van dentro de
     * un reporte. Apunta directo al servicio y no al gateway, por el mismo
     * criterio que {@link #queryServiceBaseUrl}: ya estamos dentro de la red.
     */
    private String fileServiceBaseUrl = "http://file-service:8086";

    /**
     * Secreto compartido con file-service ({@code files.internal-token}) para
     * bajar archivos sin JWT. Vacio = el reporte sale sin imagenes, no falla.
     */
    private String fileInternalToken;

    /** Timeout de cada descarga de imagen. Mucho menor que el de una consulta:
     *  una foto que tarda medio minuto es una foto que no vamos a esperar. */
    private java.time.Duration fileRequestTimeout = java.time.Duration.ofSeconds(20);

    /**
     * Tope por imagen. El PDF se exporta entero en memoria, asi que una
     * imagen desmedida multiplicada por las paginas de un grupo es un OOM.
     * Al superarlo se omite ESA imagen, no el reporte.
     */
    private int maxImageBytes = 4 * 1024 * 1024;

    /** clave del reporte -> definicion. */
    private Map<String, Report> reports = new LinkedHashMap<>();

    public String getQueryServiceBaseUrl() { return queryServiceBaseUrl; }
    public void setQueryServiceBaseUrl(String v) { this.queryServiceBaseUrl = v; }

    public int getMaxRows() { return maxRows; }
    public void setMaxRows(int v) { this.maxRows = v; }

    public java.time.Duration getRequestTimeout() { return requestTimeout; }
    public void setRequestTimeout(java.time.Duration v) { this.requestTimeout = v; }

    public String getFileServiceBaseUrl() { return fileServiceBaseUrl; }
    public void setFileServiceBaseUrl(String v) { this.fileServiceBaseUrl = v; }

    public String getFileInternalToken() { return fileInternalToken; }
    public void setFileInternalToken(String v) { this.fileInternalToken = v; }

    public java.time.Duration getFileRequestTimeout() { return fileRequestTimeout; }
    public void setFileRequestTimeout(java.time.Duration v) { this.fileRequestTimeout = v; }

    public int getMaxImageBytes() { return maxImageBytes; }
    public void setMaxImageBytes(int v) { this.maxImageBytes = v; }

    public Map<String, Report> getReports() { return reports; }
    public void setReports(Map<String, Report> v) { this.reports = v; }

    /** Un reporte del catalogo. */
    public static class Report {

        /**
         * Ruta del endpoint sin paginar en el query-service, tal como
         * quedo en {@code public.query.path_template} (V67).
         */
        private String path;

        /**
         * Instancia de query-service donde vive {@link #path}. Opcional:
         * vacio = {@link ReportingProperties#queryServiceBaseUrl}, que es
         * el caso de todos los reportes academicos (catalogo eval-col).
         *
         * <p>Existe porque el catalogo NO es unico: cada microservicio
         * registrado tiene su propia instancia de query-service, con su
         * propio backend. Los reportes de Auditoria salen de
         * {@code audit-clickhouse-cval}, que habla ClickHouse y ni siquiera
         * tiene conexion a Postgres — pedirle {@code /audits/query} a la
         * instancia de eval-col responde 404, no un reporte vacio. Sin este
         * campo, "exportar" quedaria disponible solo para los dominios que
         * comparten catalogo con el primero que se implemento.
         */
        private String baseUrl;

        /** Titulo impreso en el PDF y nombre de la hoja del Excel. */
        private String title;

        /** Prefijo del archivo descargado; se le agrega la fecha. */
        private String fileName;

        /**
         * Columnas a mostrar, en orden: clave de la fila -> encabezado.
         * Si queda vacio se usan todas las claves que traiga la primera
         * fila, con la clave como encabezado. Declararlas sirve para
         * dejar fuera los ids internos y para fijar el orden, que en un
         * Map de JSON no esta garantizado.
         */
        private Map<String, String> columns = new LinkedHashMap<>();

        /**
         * Columnas cuyo valor es un {@code PK_TARCHIVO} y que la plantilla
         * consume como imagen, no como texto.
         *
         * <p>Hace falta declararlas porque el render aplana toda celda a
         * String: sin esta lista un pk llegaria a la plantilla como el texto
         * "1234" y el hueco de la foto saldria vacio. Con ella, el renderer
         * cambia el pk por los bytes antes de llenar el reporte.
         *
         * <p>Solo tiene efecto en PDF con plantilla propia. El Excel no sabe
         * de imagenes y sigue exportando el pk.
         */
        private java.util.List<String> imageFields = new java.util.ArrayList<>();

        /**
         * Formatos que este reporte acepta. Vacio = los dos. Un boletin no es
         * una grilla: pedirlo en Excel produciria una fila ilegible por
         * estudiante, asi que se declara {@code [pdf]} y se responde 400.
         */
        private java.util.List<String> formats = new java.util.ArrayList<>();

        public String getPath() { return path; }
        public void setPath(String v) { this.path = v; }

        public String getBaseUrl() { return baseUrl; }
        public void setBaseUrl(String v) { this.baseUrl = v; }

        public String getTitle() { return title; }
        public void setTitle(String v) { this.title = v; }

        public String getFileName() { return fileName; }
        public void setFileName(String v) { this.fileName = v; }

        public Map<String, String> getColumns() { return columns; }
        public void setColumns(Map<String, String> v) { this.columns = v; }

        public java.util.List<String> getImageFields() { return imageFields; }
        public void setImageFields(java.util.List<String> v) { this.imageFields = v; }

        public java.util.List<String> getFormats() { return formats; }
        public void setFormats(java.util.List<String> v) { this.formats = v; }
    }
}
