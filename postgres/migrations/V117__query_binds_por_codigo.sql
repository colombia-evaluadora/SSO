-- =============================================================================
-- V117 — los binds de los filtros acompañan el cambio de id a codigo (V116).
--
-- V116 cambio el tipo de seis parametros en las funciones de listado. Las filas
-- de public.query seguian casteando esos binds a BIGINT[], asi que sin esto la
-- llamada no resuelve: PG busca una funcion con la firma vieja.
--
-- OJO con el nombre del tipo en param_types: es "TEXT[]", NO "VARCHAR[]".
-- ParamTypes.CURATED (modulo common) solo conoce TEXT[], BIGINT[], INTEGER[],
-- NUMERIC[], BOOLEAN[], TIME[]... Un nombre fuera de ese set NO se rechaza: el
-- binder simplemente no lo reconoce como array, serializa el valor como texto
-- plano y PG recibe el JSON crudo. El sintoma es
--
--     sqlState=22P02: malformed array literal: "[533]"
--
-- que el mapeador traduce a "Un valor enviado no tiene el formato o el rango
-- esperado" — un mensaje que no apunta para ningun lado. El CAST del SQL sigue
-- siendo VARCHAR[] porque es lo que espera la firma de la funcion; el que tiene
-- que decir TEXT[] es param_types. Esa asimetria ya existia: el filtro
-- BODY.FILTERS.STATUSES de funcionarios, que funcionaba desde antes, declara
-- TEXT[] y castea a VARCHAR[].
--
-- Se identifican por la clave en param_types y no por el texto del SQL, para
-- que la migracion sea re-ejecutable incluso sobre filas que ya quedaron a
-- medias.
--
-- BODY.FILTERS.IDS NO entra aca: sigue siendo BIGINT[]. Es el filtro de
-- "exportar seleccionados", donde el front manda las llaves de las filas
-- tildadas — ahi el id SI es lo correcto, porque identifica filas concretas.
-- Tampoco entra BODY.FILTERS.CAMPUSID: ver la nota al final de V116.
-- =============================================================================

DO $$
DECLARE
    v_bind TEXT;
BEGIN
    FOREACH v_bind IN ARRAY ARRAY[
        'BODY.FILTERS.DEPARTMENT',
        'BODY.FILTERS.MUNICIPALITY',
        'BODY.FILTERS.STATUS',
        'BODY.FILTERS.ZONES',
        'BODY.FILTERS.ROLES',
        'BODY.FILTERS.WORKSCHEDULES'
    ] LOOP
        UPDATE public.query
           SET query = replace(query,
                               'CAST(:' || v_bind || ' AS BIGINT[])',
                               'CAST(:' || v_bind || ' AS VARCHAR[])'),
               param_types = param_types || jsonb_build_object(v_bind, 'TEXT[]')
         WHERE param_types ? v_bind;
    END LOOP;
END
$$;
