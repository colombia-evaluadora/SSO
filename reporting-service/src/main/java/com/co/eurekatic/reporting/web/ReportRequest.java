package com.co.eurekatic.reporting.web;

import java.util.Map;

/**
 * Cuerpo de {@code POST /reportes/{clave}}.
 *
 * <p>Es a proposito el MISMO cuerpo que el listado de pantalla menos
 * {@code pageIndex} / {@code pageSize}: el front ya arma este objeto
 * para la tabla, asi que exportar es mandar lo que ya tiene en la mano.
 * Si se pidiera una forma distinta, el front tendria que traducir sus
 * filtros a otro vocabulario y ahi es donde el reporte empieza a
 * mostrar algo distinto de lo que se ve en la pantalla.
 *
 * @param format  {@code "pdf"} o {@code "excel"}
 * @param filters filtros elegidos; null o vacio = sin filtrar = todo
 * @param sorting {@code {id, desc}} del orden de la tabla; opcional
 */
public record ReportRequest(
        String format,
        Map<String, Object> filters,
        Map<String, Object> sorting) {
}
