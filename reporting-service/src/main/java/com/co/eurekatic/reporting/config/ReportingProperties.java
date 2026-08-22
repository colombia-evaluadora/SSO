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

    /** clave del reporte -> definicion. */
    private Map<String, Report> reports = new LinkedHashMap<>();

    public String getQueryServiceBaseUrl() { return queryServiceBaseUrl; }
    public void setQueryServiceBaseUrl(String v) { this.queryServiceBaseUrl = v; }

    public int getMaxRows() { return maxRows; }
    public void setMaxRows(int v) { this.maxRows = v; }

    public java.time.Duration getRequestTimeout() { return requestTimeout; }
    public void setRequestTimeout(java.time.Duration v) { this.requestTimeout = v; }

    public Map<String, Report> getReports() { return reports; }
    public void setReports(Map<String, Report> v) { this.reports = v; }

    /** Un reporte del catalogo. */
    public static class Report {

        /**
         * Ruta del endpoint sin paginar en el query-service, tal como
         * quedo en {@code public.query.path_template} (V67).
         */
        private String path;

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

        public String getPath() { return path; }
        public void setPath(String v) { this.path = v; }

        public String getTitle() { return title; }
        public void setTitle(String v) { this.title = v; }

        public String getFileName() { return fileName; }
        public void setFileName(String v) { this.fileName = v; }

        public Map<String, String> getColumns() { return columns; }
        public void setColumns(Map<String, String> v) { this.columns = v; }
    }
}
