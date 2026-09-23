package com.co.eurekatic.reporting.web;

import java.util.List;
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
 * @param columns claves de columna a incluir, EN ORDEN -- mismo criterio que
 *                el resto del record: el front manda lo que ya tiene en la
 *                mano (las columnas visibles de su tabla). Null o vacio =
 *                todas las declaradas en {@code reporting.reports.<clave>.columns}
 *                (comportamiento de siempre, sin este campo). Una clave que
 *                no este en ese mapa configurado se ignora en silencio --
 *                {@code columns} filtra/reordena el catalogo declarado, no
 *                agrega columnas nuevas que no estuvieran pensadas para
 *                exportarse (ver {@code ColumnLayout.resolver}).
 * @param filtersLabel el resumen de filtros YA ESCRITO para el membrete,
 *                opcional. {@code filters} son los binds de la consulta, asi
 *                que ahi los filtros son ids: impresos salen "Fk Tgrupo:
 *                11474" en vez de "Grupo: 5°01", que es lo unico que el
 *                lector del archivo puede interpretar. El front tiene los
 *                nombres en pantalla, asi que manda la linea hecha. Cuando
 *                viene en blanco o no viene, el membrete se arma como
 *                siempre a partir de {@code filters} -- ningun reporte
 *                existente cambia por esto.
 */
public record ReportRequest(
        String format,
        Map<String, Object> filters,
        Map<String, Object> sorting,
        List<String> columns,
        String filtersLabel) {
}
