-- V436 -- Preescolar toma asistencia por ASIGNATURA + bloque como el resto
-- (fn_asistencia_grupo_es_formativo -> FALSE), y Seguimiento gana los filtros
-- sueltos de JORNADA y GRADO (fn_asistencia_listar_seguimiento + catalogo).
-- Va aparte y no editando V220 porque V220 ya esta aplicada (release a86104b):
-- asi se revierte con un CREATE OR REPLACE.
-- Depende de: V220 (modulo), V221 / V228 (catalogo HTTP).


-- 1. El pivote: con FALSE, el calendario manda todos los grupos por la rama
-- evaluativa (THORARIO) y actividades_programadas deja de devolver filas.
CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_grupo_es_formativo(
    p_fk_tgrupo BIGINT
)
RETURNS BOOLEAN
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    -- p_fk_tgrupo se ignora a proposito: la firma se conserva para no tocar
    -- a los llamadores mientras el modo por actividad siga en pie.
    SELECT FALSE;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_grupo_es_formativo(BIGINT)
    IS 'Devuelve FALSE siempre: ningun grupo toma asistencia por ACTIVIDAD. Preescolar pasa a la sesion por asignatura + bloque de horario (THORARIO), igual que el resto de niveles. Antes discriminaba por TNIVEL_ENSENANZA.CODIGO = ''1''. El modo formativo NO se elimino -- siguen en pie la columna TASISTENCIA.FK_TACTIVIDAD, CK_TASISTENCIA_CONTEXTO, los parametros p_fk_tactividad de fn_asistencia_registrar_bulk / fn_asistencia_estudiantes_sesion / fn_asistencia_listar_seguimiento y la rama formativa de fn_asistencia_calendario: quedan inalcanzables mientras esta funcion devuelva FALSE. Para revertir, reponer el cuerpo de V220 (el SELECT sobre TGRUPO -> TGRADO -> TNIVEL_ENSENANZA).';


-- 2. Seguimiento: JORNADA y GRADO eran solo un recorte del catalogo en el
-- cliente; ahora son filtros reales y sueltos. Comparan contra
-- v_asistencia_detalle.jornada / .grado (los NOMBRE que ya devuelve el
-- calendario, de modo que el front reenvia lo que recibio). Cambia la aridad
-- (12 -> 14): hay que soltar la firma vieja o quedan dos sobrecargas.
DROP FUNCTION IF EXISTS academico_test.fn_asistencia_listar_seguimiento(
    BIGINT, DATE, DATE, BIGINT, BIGINT, NUMERIC, TEXT, INT, INT, TEXT, TEXT, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_listar_seguimiento(
    p_pk_usuario      BIGINT  DEFAULT NULL,   -- alcance (fn_asistencia_puede_ver)
    p_fecha_desde     DATE    DEFAULT NULL,
    p_fecha_hasta     DATE    DEFAULT NULL,
    p_fk_tgrupo       BIGINT  DEFAULT NULL,
    p_fk_tasignatura  BIGINT  DEFAULT NULL,
    p_tipo_asistencia NUMERIC DEFAULT NULL,   -- VALOR de TIPO_ASISTENCIA
    p_search          TEXT    DEFAULT NULL,
    p_page_index      INT     DEFAULT 0,
    p_page_size       INT     DEFAULT 10,
    p_sort_by         TEXT    DEFAULT NULL,   -- estudiante|fecha|tipo|grupo|asignatura|actividad|documento
    p_sort_dir        TEXT    DEFAULT NULL,   -- asc|desc
    p_fk_tactividad   BIGINT  DEFAULT NULL,   -- filtro formativo, independiente de la asignatura
    -- Ejes independientes: el usuario puede pedir "toda la jornada de la
    -- manana" o "todos los grados 5" sin elegir un grupo.
    p_jornada         TEXT    DEFAULT NULL,   -- NOMBRE de TLISTA_VALOR JORNADA
    p_grado           TEXT    DEFAULT NULL    -- NOMBRE de TGRADO
)
RETURNS TABLE (
    pk_tasistencia        BIGINT,
    estudiante            TEXT,
    documento             VARCHAR,
    grupo                 VARCHAR,
    asignatura            VARCHAR,
    fk_tactividad         BIGINT,
    actividad             VARCHAR,
    es_formativa          BOOLEAN,
    fecha                 DATE,
    bloque                NUMERIC,
    hora_inicio           TIMESTAMP,
    hora_fin              TIMESTAMP,
    tipo_asistencia_valor INTEGER,
    tipo_asistencia       VARCHAR,
    observacion           VARCHAR,
    tiene_soporte         BOOLEAN,
    fk_soporte_archivo    BIGINT,
    soporte_nombre        VARCHAR,
    total_estudiantes     BIGINT,
    ausentes              BIGINT,
    total_count           BIGINT
)
LANGUAGE plpgsql STABLE AS $function$
DECLARE
    v_col TEXT;
    v_dir TEXT;
BEGIN
    v_col := CASE lower(coalesce(p_sort_by, ''))
        WHEN 'estudiante' THEN 'estudiante'
        WHEN 'documento'  THEN 'documento'
        WHEN 'fecha'      THEN 'fecha'
        WHEN 'tipo'       THEN 'tipo_asistencia_valor'
        WHEN 'grupo'      THEN 'grupo'
        WHEN 'asignatura' THEN 'asignatura'
        WHEN 'actividad'  THEN 'actividad'
        ELSE 'fecha'
    END;
    v_dir := CASE WHEN lower(coalesce(p_sort_dir, '')) = 'asc' THEN 'ASC' ELSE 'DESC' END;

    RETURN QUERY EXECUTE format($q$
        SELECT
            pk_tasistencia, estudiante, documento, grupo, asignatura,
            fk_tactividad, actividad, es_formativa, fecha,
            bloque, hora_inicio, hora_fin, tipo_asistencia_valor, tipo_asistencia,
            observacion, tiene_soporte, fk_soporte_archivo, soporte_nombre,
            -- DISTINCT no existe en funciones de ventana: se cuenta la
            -- primera aparicion de cada matricula (rn_mat = 1).
            SUM((rn_mat = 1)::int) OVER ()::BIGINT                          AS total_estudiantes,
            SUM((rn_aus = 1)::int) OVER ()::BIGINT                          AS ausentes,
            COUNT(*) OVER ()::BIGINT                                        AS total_count
        FROM (
            SELECT
                d.pk_tasistencia, d.estudiante, d.documento, d.grupo, d.asignatura,
                d.fk_tactividad, d.actividad, d.es_formativa,
                d.fecha, d.bloque, d.hora_inicio, d.hora_fin,
                d.tipo_valor  AS tipo_asistencia_valor,
                d.tipo_nombre AS tipo_asistencia,
                d.observacion, d.tiene_soporte, d.fk_soporte_archivo, d.soporte_nombre,
                row_number() OVER (PARTITION BY d.fk_tmatricula
                                       ORDER BY d.pk_tasistencia)           AS rn_mat,
                CASE WHEN d.es_ausente
                     THEN row_number() OVER (PARTITION BY d.fk_tmatricula, d.es_ausente
                                                 ORDER BY d.pk_tasistencia)
                     ELSE 0 END                                             AS rn_aus
              FROM academico_test.v_asistencia_detalle d
             WHERE ($2 IS NULL OR d.fecha >= $2)
               AND ($3 IS NULL OR d.fecha <= $3)
               AND ($4 IS NULL OR d.fk_tgrupo = $4)
               AND ($5 IS NULL OR d.fk_tasignatura = $5)
               AND ($10 IS NULL OR d.fk_tactividad = $10)
               AND ($6 IS NULL OR d.tipo_valor = $6::INT)
               AND ($11 IS NULL OR d.jornada = $11)
               AND ($12 IS NULL OR d.grado   = $12)
               -- La busqueda libre incluye la ACTIVIDAD: en preescolar es lo
               -- que la pantalla muestra en esa columna, y buscar por
               -- asignatura ahi no encuentra nada (viene NULL).
               AND ($7 IS NULL OR (
                       d.estudiante  ILIKE '%%' || $7 || '%%' OR
                       d.documento   ILIKE '%%' || $7 || '%%' OR
                       d.grupo       ILIKE '%%' || $7 || '%%' OR
                       d.asignatura  ILIKE '%%' || $7 || '%%' OR
                       d.actividad   ILIKE '%%' || $7 || '%%' OR
                       d.tipo_nombre ILIKE '%%' || $7 || '%%'
                   ))
               -- Alcance por rol. Se evalua al final y una sola vez por
               -- grupo distinto (fn_asistencia_puede_ver es STABLE).
               AND academico_test.fn_asistencia_puede_ver($1, d.fk_tgrupo)
        ) q
        ORDER BY %s %s, pk_tasistencia
        LIMIT NULLIF($9, 0)
       OFFSET COALESCE($8, 0) * COALESCE(NULLIF($9, 0), 0)
    $q$, v_col, v_dir)
    USING p_pk_usuario, p_fecha_desde, p_fecha_hasta, p_fk_tgrupo, p_fk_tasignatura,
          p_tipo_asistencia, NULLIF(TRIM(p_search), ''), p_page_index, p_page_size,
          p_fk_tactividad, NULLIF(TRIM(p_jornada), ''), NULLIF(TRIM(p_grado), '');
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_asistencia_listar_seguimiento(
    BIGINT, DATE, DATE, BIGINT, BIGINT, NUMERIC, TEXT, INT, INT, TEXT, TEXT, BIGINT, TEXT, TEXT
) IS 'Pantalla Seguimiento: listado paginado sobre v_asistencia_detalle con filtros rango de fecha / JORNADA / GRADO / grupo / asignatura / ACTIVIDAD / tipo (VALOR) / busqueda libre (estudiante, documento, grupo, asignatura, actividad, estado). Todos los filtros son INDEPENDIENTES y combinables, se aplican en AND: p_jornada, p_grado y p_fk_tasignatura no exigen grupo. p_jornada compara contra el NOMBRE de la jornada y p_grado contra el NOMBRE del grado -- los mismos valores que devuelve fn_asistencia_calendario, para que el front reenvie lo que recibio; el CODIGO del grado viaja aparte (grado_valor) y no se filtra por el. Alcance por rol via fn_asistencia_puede_ver. total_estudiantes y ausentes cuentan ESTUDIANTES DISTINTOS (no registros) del set filtrado completo, y total_count sus filas -- las tres son ventanas independientes de la pagina. Orden por estudiante|documento|fecha|tipo|grupo|asignatura|actividad.';


-- 3. Catalogo HTTP: listado (V221) y export-all (V228) pasan los binds nuevos.
-- /asistencias/reporte (V290) no se toca: ahi GRUPO es obligatorio. Se parchea
-- el texto almacenado en vez de reescribir la fila, para no duplicar el SQL del
-- que V221/V228 son dueñas; el guard NOT LIKE hace el UPDATE idempotente.
UPDATE public.query
   SET query = replace(
           query,
           '    p_search          => CAST(:BODY.FILTERS.SEARCH AS TEXT),',
           '    p_search          => CAST(:BODY.FILTERS.SEARCH AS TEXT),' || chr(10) ||
           '    p_jornada         => CAST(:BODY.FILTERS.JORNADA AS TEXT),' || chr(10) ||
           '    p_grado           => CAST(:BODY.FILTERS.GRADO AS TEXT),'),
       param_types = param_types || '{"BODY.FILTERS.JORNADA": "VARCHAR",
                                      "BODY.FILTERS.GRADO":   "VARCHAR"}'::JSONB
 WHERE uuid IN ('asis-seguimiento', 'eval-col-asistencias-seguimiento-export-all-001')
   AND query LIKE '%p_search          => CAST(:BODY.FILTERS.SEARCH AS TEXT),%'
   AND query NOT LIKE '%p_jornada%';

-- Formato de los binds nuevos (query_param_constraint, V70/V83): texto corto,
-- mismo criterio que SEARCH. Sin fila aqui el parametro pasa sin validar.
INSERT INTO public.query_param_constraint
       (query_id, param_key, only_positive, allow_decimals, max_digits,
        numeric_text, min_length, max_length, min_value, max_value)
SELECT q.id_query, c.param_key, NULL::boolean, NULL::boolean, NULL::integer,
       FALSE, NULL::integer, c.max_length, NULL::numeric, NULL::numeric
  FROM public.query q
  CROSS JOIN (VALUES
      ('BODY.FILTERS.JORNADA', 60),
      ('BODY.FILTERS.GRADO',   60)
  ) AS c(param_key, max_length)
 WHERE q.uuid IN ('asis-seguimiento', 'eval-col-asistencias-seguimiento-export-all-001')
ON CONFLICT (query_id, param_key) DO UPDATE
   SET max_length = EXCLUDED.max_length,
       numeric_text = EXCLUDED.numeric_text;
