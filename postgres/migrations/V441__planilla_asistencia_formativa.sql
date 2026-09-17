-- ===========================================================================
-- V441 — Planilla de calificacion: fecha de asistencia por celda, actividad
-- formativa y metodo de valoracion del instrumento OTRO.
--
-- Supersede las dos funciones de pantalla de V239 (header y cuerpo): las dos
-- cambian su RETURNS TABLE, por eso el DROP de la firma vieja.
--
-- Depende de: V239 (planilla, fn_planilla_actividades_universo), V227
-- (gate de asistencia, fn_asistencia_tipo_pk), V241 (metodo OTRO, forma de
-- `evidencias`), V243 (formativa, assert preescolar, TACTIVIDAD_SOPORTE).
-- ===========================================================================

SET search_path TO academico_test, public;

-- Soporte del LATERAL por celda: la busqueda es (matricula, llave, fecha) y
-- hoy solo hay un indice (fk_tmatricula, fecha) que trae todas las
-- asignaturas del estudiante para filtrarlas despues.
CREATE INDEX IF NOT EXISTS idx_tasistencia_mat_asig_fecha
    ON academico_test.TASISTENCIA (FK_TMATRICULA, FK_TASIGNATURA, FECHA)
 WHERE ACTIVE = TRUE AND FK_TASIGNATURA IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_tasistencia_mat_act_fecha
    ON academico_test.TASISTENCIA (FK_TMATRICULA, FK_TACTIVIDAD, FECHA)
 WHERE ACTIVE = TRUE AND FK_TACTIVIDAD IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 1. HEADER — + es_formativa + metodo_valoracion.
--
-- ES_EVALUATIVA es un flag manual de TACTIVIDAD (DEFAULT 'S') y NO dice si la
-- actividad cuelga de una unidad formativa: se conserva tal cual y se agrega
-- es_formativa (fn_actividad_es_formativa), que es lo que decide si el front
-- abre el popover de OBSERVACION en vez del de nota.
-- metodo_valoracion solo aplica al instrumento OTRO; NULL en el resto.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_planilla_columnas_listar(
    BIGINT, BIGINT, BIGINT, BIGINT, DATE, DATE, VARCHAR);

CREATE OR REPLACE FUNCTION academico_test.fn_planilla_columnas_listar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_tasignatura         BIGINT,
    p_fk_tgrado              BIGINT  DEFAULT NULL,
    p_fecha_desde            DATE    DEFAULT NULL,
    p_fecha_hasta            DATE    DEFAULT NULL,
    p_search_actividad       VARCHAR DEFAULT NULL
)
RETURNS TABLE (
    orden_columna                  INTEGER,
    pk_tactividad                  BIGINT,
    titulo                         VARCHAR,
    fk_tunidad                     BIGINT,
    unidad                         VARCHAR,
    fk_tlv_instrumento_evaluacion  BIGINT,
    instrumento                    VARCHAR,
    instrumento_nombre             VARCHAR,
    metodo_valoracion              VARCHAR,
    ponderacion                    NUMERIC,
    nota_maxima                    NUMERIC,
    es_evaluativa                  VARCHAR,
    es_formativa                   BOOLEAN,
    fecha_inicio                   DATE,
    fecha_cierre                   DATE,
    estudiantes_asignados          BIGINT,
    estudiantes_calificados        BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', p_fk_tgrupo
    );
    PERFORM academico_test.fn_planilla_grupo_asignatura_assert(
        p_fk_tgrupo, p_fk_tasignatura, p_fk_tgrado
    );

    RETURN QUERY
    SELECT uni.orden_columna,
           a.PK_TACTIVIDAD,
           a.TITULO,
           a.FK_TUNIDAD,
           u.NOMBRE,
           a.FK_TLV_INSTRUMENTO_EVALUACION,
           lvi.VALOR::VARCHAR,
           lvi.NOMBRE::VARCHAR,
           CASE WHEN lvi.VALOR = 'OTRO'
                THEN academico_test.fn_actividad_otro_metodo_valoracion(a.PK_TACTIVIDAD)
           END::VARCHAR,
           a.PONDERACION,
           a.NOTA_MAXIMA,
           a.ES_EVALUATIVA::VARCHAR,
           academico_test.fn_actividad_es_formativa(a.PK_TACTIVIDAD),
           a.FECHA_INICIO,
           a.FECHA_CIERRE,
           prog.asignados,
           prog.calificados
      FROM academico_test.fn_planilla_actividades_universo(
               p_fk_tgrupo, p_fk_tasignatura, p_fecha_desde, p_fecha_hasta, p_search_actividad
           ) uni
      JOIN academico_test.TACTIVIDAD a ON a.PK_TACTIVIDAD = uni.pk_tactividad
      LEFT JOIN academico_test.TUNIDAD u        ON u.PK_TUNIDAD = a.FK_TUNIDAD
      LEFT JOIN academico_test.TLISTA_VALOR lvi ON lvi.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
      -- Progreso acotado a ESTE grupo: la actividad puede tener estudiantes
      -- de otros grupos y esta pantalla es la planilla de uno solo.
      LEFT JOIN LATERAL (
          SELECT COUNT(*)::BIGINT AS asignados,
                 COUNT(*) FILTER (
                     WHERE n.PK_TACTIVIDAD_NOTA IS NOT NULL
                       AND COALESCE(n.DEFINITIVA, n.CALIFICACION) IS NOT NULL
                 )::BIGINT AS calificados
            FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
            JOIN academico_test.TMATRICULA m ON m.PK_TMATRICULA = ae.FK_TMATRICULA
            LEFT JOIN academico_test.TACTIVIDAD_NOTA n
                   ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                  AND n.ACTIVE = TRUE
           WHERE ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
             AND ae.ACTIVE = TRUE
             AND m.FK_TGRUPO = p_fk_tgrupo
      ) prog ON TRUE
     ORDER BY uni.orden_columna;
END;
$$;

-- ---------------------------------------------------------------------------
-- 2. CUERPO — la celda gana fechaAsistencia / tieneAsistencia / esFormativa /
-- evidencias.
--
-- FECHA: el endpoint de calificar manda BODY.FECHA (o CURRENT_DATE) y el
-- assert de V227/V243 exige una TASISTENCIA ACTIVA para esa fecha EXACTA que
-- ademas no sea inasistencia injustificada (TIPO_ASISTENCIA VALOR=2). Aqui se
-- devuelve, por celda, una fecha que ese assert aceptaria:
--   * llave evaluativa (FK_TASIGNATURA de la actividad) o preescolar
--     (FK_TACTIVIDAD) segun es_formativa, para que coincida con el assert
--     que se va a ejecutar;
--   * ventana [FECHA_INICIO, FECHA_CIERRE] de la actividad, con extremo NULL
--     tratado como abierto (mismo criterio de tolerancia de
--     fn_actividad_estado); sin ninguna de las dos fechas, ventana abierta;
--   * desempate: la mas reciente <= hoy; si no hay ninguna pasada, la
--     primera futura de la ventana.
-- NULL / tieneAsistencia=false => la celda no es calificable hoy.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_planilla_calificaciones_listar(
    BIGINT, BIGINT, BIGINT, BIGINT, DATE, DATE, VARCHAR, VARCHAR, INTEGER, INTEGER);

CREATE OR REPLACE FUNCTION academico_test.fn_planilla_calificaciones_listar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_tasignatura         BIGINT,
    p_fk_tgrado              BIGINT  DEFAULT NULL,
    p_fecha_desde            DATE    DEFAULT NULL,
    p_fecha_hasta            DATE    DEFAULT NULL,
    p_search_actividad       VARCHAR DEFAULT NULL,
    p_search_estudiante      VARCHAR DEFAULT NULL,
    p_limite                 INTEGER DEFAULT 50,
    p_offset                 INTEGER DEFAULT 0
)
RETURNS TABLE (
    pk_tmatricula         BIGINT,
    pk_testudiante        BIGINT,
    nombre_estudiante     VARCHAR,
    definitiva_proyectada NUMERIC,
    definitiva_registrada NUMERIC,
    tendencia             VARCHAR,
    celdas                JSONB,
    total_count           BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    -- Se resuelve UNA vez: dentro del LATERAL de la celda se evaluaria por fila.
    v_tipo_inasistencia BIGINT := academico_test.fn_asistencia_tipo_pk(2);
    v_hoy               DATE   := CURRENT_DATE;
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', p_fk_tgrupo
    );
    PERFORM academico_test.fn_planilla_grupo_asignatura_assert(
        p_fk_tgrupo, p_fk_tasignatura, p_fk_tgrado
    );

    RETURN QUERY
    WITH columnas AS MATERIALIZED (
        -- MATERIALIZED a proposito: sin el, el planner inlinearia este CTE
        -- dentro del LATERAL de las celdas y recalcularia el universo de
        -- columnas (y es_formativa) una vez POR ESTUDIANTE de la pagina.
        SELECT uni.orden_columna,
               uni.pk_tactividad,
               uni.fk_tunidad,
               a.FK_TASIGNATURA AS fk_tasignatura,
               a.FECHA_INICIO   AS fecha_inicio,
               a.FECHA_CIERRE   AS fecha_cierre,
               academico_test.fn_actividad_es_formativa(uni.pk_tactividad) AS es_formativa
          FROM academico_test.fn_planilla_actividades_universo(
                   p_fk_tgrupo, p_fk_tasignatura, p_fecha_desde, p_fecha_hasta, p_search_actividad
               ) uni
          JOIN academico_test.TACTIVIDAD a ON a.PK_TACTIVIDAD = uni.pk_tactividad
    ),
    base AS (
        -- Filtro + orden + paginacion tocando solo matricula/estudiante/usuario:
        -- los agregados caros van DESPUES, contra las <= p_limite filas.
        SELECT m.PK_TMATRICULA,
               es.PK_TESTUDIANTE,
               NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                          u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO)), '')::VARCHAR AS nombre,
               COUNT(*) OVER() AS total
          FROM academico_test.TMATRICULA m
          JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
          JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO = es.FK_TUSUARIO
         WHERE m.FK_TGRUPO = p_fk_tgrupo
           AND m.ACTIVE = TRUE
           AND (p_search_estudiante IS NULL
                OR TRIM(p_search_estudiante) = ''
                OR TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                       u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO))
                       ILIKE '%' || TRIM(p_search_estudiante) || '%')
         ORDER BY NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                             u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO)), ''),
                  m.PK_TMATRICULA
         LIMIT GREATEST(p_limite, 1)
        OFFSET GREATEST(p_offset, 0)
    )
    SELECT b.PK_TMATRICULA,
           b.PK_TESTUDIANTE,
           b.nombre,
           def.proyectada,
           reg.registrada,
           CASE
               WHEN def.proyectada IS NULL OR reg.registrada IS NULL THEN NULL
               WHEN def.proyectada > reg.registrada THEN 'SUBE'
               WHEN def.proyectada < reg.registrada THEN 'BAJA'
               ELSE 'IGUAL'
           END::VARCHAR,
           COALESCE(cel.celdas, '[]'::jsonb),
           b.total
      FROM base b
      LEFT JOIN LATERAL (
          SELECT academico_test.fn_planilla_definitiva_proyectada(
                     b.PK_TMATRICULA, p_fk_tasignatura) AS proyectada
      ) def ON TRUE
      -- Linea base de la flecha verde/roja: NULL mientras nadie consolide
      -- TUNIDAD_NOTA. Se deja calculado para no cambiar el contrato despues.
      LEFT JOIN LATERAL (
          SELECT ROUND(AVG(COALESCE(un.DEFINITIVA, un.CALIFICACION)), 2) AS registrada
            FROM academico_test.TUNIDAD_NOTA un
            JOIN academico_test.TUNIDAD tu ON tu.PK_TUNIDAD = un.FK_TUNIDAD
           WHERE un.FK_TMATRICULA = b.PK_TMATRICULA
             AND un.ACTIVE = TRUE
             AND tu.FK_TASIGNATURA = p_fk_tasignatura
      ) reg ON TRUE
      LEFT JOIN LATERAL (
          SELECT jsonb_agg(jsonb_build_object(
                     'ordenColumna',            c.orden_columna,
                     'pkTactividad',            c.pk_tactividad,
                     'pkTunidad',               c.fk_tunidad,
                     -- Llave que necesitan fn_actividad_nota_obtener (precargar
                     -- el popover) y fn_actividad_nota_calificar* (guardar).
                     -- NULL cuando la celda no aplica.
                     'pkTactividadEstudiante',  ae.PK_TACTIVIDAD_ESTUDIANTE,
                     'esFormativa',             c.es_formativa,
                     'estado',
                         CASE
                             WHEN ae.PK_TACTIVIDAD_ESTUDIANTE IS NULL          THEN 'NO_ASIGNADA'
                             WHEN COALESCE(n.CALIFICABLE, 'S') = 'N'           THEN 'NO_CALIFICABLE'
                             WHEN COALESCE(n.DEFINITIVA, n.CALIFICACION) IS NULL THEN 'SIN_CALIFICAR'
                             ELSE 'CALIFICADA'
                         END,
                     'calificacion',  n.CALIFICACION,
                     'recuperacion',  n.RECUPERACION,
                     'definitiva',    n.DEFINITIVA,
                     'nota',          COALESCE(n.DEFINITIVA, n.CALIFICACION),
                     'calificable',   n.CALIFICABLE,
                     'observacion',   n.OBSERVACION,
                     'fechaAsistencia', asi.fecha,
                     'tieneAsistencia', (asi.fecha IS NOT NULL),
                     'evidencias',    COALESCE(ev.evidencias, '[]'::jsonb))
                     ORDER BY c.orden_columna) AS celdas
            FROM columnas c
            LEFT JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
                   ON ae.FK_TACTIVIDAD = c.pk_tactividad
                  AND ae.FK_TMATRICULA = b.PK_TMATRICULA
                  AND ae.ACTIVE = TRUE
            LEFT JOIN academico_test.TACTIVIDAD_NOTA n
                   ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                  AND n.ACTIVE = TRUE
            LEFT JOIN LATERAL (
                SELECT s.FECHA AS fecha
                  FROM academico_test.TASISTENCIA s
                 WHERE s.FK_TMATRICULA = b.PK_TMATRICULA
                   AND s.ACTIVE = TRUE
                   -- En forma de OR (no CASE) para que el planner pueda
                   -- resolver cada rama por indice.
                   AND ((c.es_formativa      AND s.FK_TACTIVIDAD  = c.pk_tactividad)
                     OR (NOT c.es_formativa  AND s.FK_TASIGNATURA = c.fk_tasignatura))
                   AND (c.fecha_inicio IS NULL OR s.FECHA >= c.fecha_inicio)
                   AND (c.fecha_cierre IS NULL OR s.FECHA <= c.fecha_cierre)
                   AND (v_tipo_inasistencia IS NULL
                        OR s.FK_TLV_TIPO_ASISTENCIA <> v_tipo_inasistencia)
                 ORDER BY (s.FECHA <= v_hoy) DESC,
                          CASE WHEN s.FECHA <= v_hoy THEN s.FECHA END DESC NULLS LAST,
                          s.FECHA
                 LIMIT 1
            ) asi ON ae.PK_TACTIVIDAD_ESTUDIANTE IS NOT NULL
            -- Adjuntos de la observacion formativa, con la MISMA forma que
            -- devuelve fn_actividad_nota_obtener. Solo filas con archivo.
            LEFT JOIN LATERAL (
                SELECT jsonb_agg(jsonb_build_object(
                           'pk',         so.PK_TACTIVIDAD_SOPORTE,
                           'fkTarchivo', so.FK_TARCHIVO,
                           'nombre',     ar.NOMBRE,
                           'fecha',      so.FECHA)
                           ORDER BY so.PK_TACTIVIDAD_SOPORTE) AS evidencias
                  FROM academico_test.TACTIVIDAD_SOPORTE so
                  LEFT JOIN academico_test.TARCHIVO ar ON ar.PK_TARCHIVO = so.FK_TARCHIVO
                 WHERE so.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                   AND so.ACTIVE = TRUE
                   AND so.FK_TARCHIVO IS NOT NULL
            ) ev ON c.es_formativa AND ae.PK_TACTIVIDAD_ESTUDIANTE IS NOT NULL
      ) cel ON TRUE
     ORDER BY b.nombre, b.PK_TMATRICULA;
END;
$$;

-- ---------------------------------------------------------------------------
-- 3. public.query — las filas de V248 se insertaron con ON CONFLICT DO
-- NOTHING: el detail se reconcilia con UPDATE (patron V253/V279).
-- ---------------------------------------------------------------------------
UPDATE public.query q
   SET detail = q.detail || ' V441 -- El HEADER agrega es_formativa (true = la actividad cuelga de una unidad FORMATIVA: el cliente abre el popover de OBSERVACION, no el de nota; ES_EVALUATIVA es otro concepto, un flag manual de la actividad con DEFAULT S) y metodo_valoracion (solo cuando instrumento = OTRO: el metodo de valoracion configurado en TACTIVIDAD_OTRO, NULL si no es OTRO o no tiene metodo).'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/planilla/columnas'
   AND q.http_method     = 'GET'
   AND q.detail NOT LIKE '%V441 --%';

UPDATE public.query q
   SET detail = q.detail || ' V441 -- Cada celda agrega esFormativa, fechaAsistencia, tieneAsistencia y evidencias. fechaAsistencia es la fecha, dentro de la ventana [fecha_inicio, fecha_cierre] de la actividad (extremo NULL = abierto), en la que ESE estudiante tiene una asistencia ACTIVA que el gate de calificacion aceptaria: llave por asignatura para las actividades normales y por actividad para las formativas, excluyendo la inasistencia injustificada (TIPO_ASISTENCIA VALOR=2). Desempate: la mas reciente <= hoy y, si no hay ninguna pasada, la primera futura de la ventana. El cliente debe mandar esa fecha en BODY.FECHA al calificar; tieneAsistencia=false (fechaAsistencia NULL) significa que la celda no es calificable todavia y debe pintarse deshabilitada, porque cualquier intento devolveria 22023. evidencias son los adjuntos de la observacion (TACTIVIDAD_SOPORTE) con la misma forma que GET del detalle de nota: [{pk, fkTarchivo, nombre, fecha}], siempre [] en celdas no formativas.'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/planilla/calificaciones'
   AND q.http_method     = 'GET'
   AND q.detail NOT LIKE '%V441 --%';
