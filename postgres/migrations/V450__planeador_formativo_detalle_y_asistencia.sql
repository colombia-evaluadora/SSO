SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_asistencia_valida(
    p_fk_tmatricula BIGINT,
    p_pk_tactividad BIGINT,
    p_fecha         DATE
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
          FROM academico_test.TASISTENCIA s
          JOIN academico_test.TACTIVIDAD a ON a.PK_TACTIVIDAD = p_pk_tactividad
         WHERE s.FK_TMATRICULA = p_fk_tmatricula
           AND s.FECHA         = p_fecha
           AND s.ACTIVE = TRUE
           AND s.FK_TLV_TIPO_ASISTENCIA IS DISTINCT FROM academico_test.fn_asistencia_tipo_pk(2)
           AND CASE
                 WHEN academico_test.fn_actividad_es_formativa(p_pk_tactividad) THEN TRUE
                 ELSE s.FK_TASIGNATURA = a.FK_TASIGNATURA
               END
    );
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_asistencia_valida(BIGINT, BIGINT, DATE)
    IS 'TRUE si el estudiante (por matricula) tiene, en p_fecha, una asistencia ACTIVA que habilita calificar u observar la actividad: alguna fila que NO sea inasistencia injustificada (TIPO_ASISTENCIA VALOR=2) y que ademas pertenezca al contexto correcto -- en una actividad FORMATIVA cualquier sesion del dia cuenta (la jornada de preescolar es continua y desde V436 la asistencia ya no se escribe por FK_TACTIVIDAD), en el resto tiene que ser la asignatura de la actividad. Con varios bloques alcanza UNA fila valida. Es la UNICA definicion de la regla: la usan el gate (fn_actividad_nota_asistencia_assert_preescolar) y, a traves de fn_actividad_asistencia_fecha_resolver, las lecturas de la planilla y de la tabla de calificaciones. V450.';

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_asistencia_fecha_resolver(
    p_fk_tmatricula BIGINT,
    p_pk_tactividad BIGINT
)
RETURNS DATE
LANGUAGE sql
STABLE
AS $$
    SELECT s.FECHA
      FROM academico_test.TASISTENCIA s
      JOIN academico_test.TACTIVIDAD a ON a.PK_TACTIVIDAD = p_pk_tactividad
     WHERE s.FK_TMATRICULA = p_fk_tmatricula
       AND s.ACTIVE = TRUE
       AND s.FECHA <= CURRENT_DATE
       AND (a.FECHA_INICIO IS NULL OR s.FECHA >= a.FECHA_INICIO)
       AND (a.FECHA_CIERRE IS NULL OR s.FECHA <= a.FECHA_CIERRE)
       AND academico_test.fn_actividad_asistencia_valida(p_fk_tmatricula, p_pk_tactividad, s.FECHA)
     ORDER BY s.FECHA DESC
     LIMIT 1;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_asistencia_fecha_resolver(BIGINT, BIGINT)
    IS 'La fecha que hay que mandar en BODY.FECHA para calificar u observar a ESE estudiante en ESA actividad: la mas reciente, dentro de la ventana [FECHA_INICIO, FECHA_CIERRE] de la actividad (extremo NULL = abierto), que fn_actividad_asistencia_valida acepta -- solo fechas <= hoy; sin ninguna, NULL. NULL = no hay ninguna pasada o de hoy que habilite, o sea que la celda no es calificable/observable todavia y cualquier intento devolveria 22023. Ya NO cae a una fecha futura de la ventana (bug: la pantalla de marcar mostraba "sin asistencia" para hoy y el gate igual dejaba guardar via esa fecha futura). Definida EN TERMINOS del predicado para que la lectura y el gate no puedan desincronizarse. V450.';


CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_asistencia_assert_preescolar(
    p_pk_tactividad_estudiante BIGINT,
    p_fecha                    DATE
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_matricula  BIGINT;
    v_pk_tactividad BIGINT;
BEGIN
    SELECT ae.FK_TMATRICULA, ae.FK_TACTIVIDAD
      INTO v_pk_matricula, v_pk_tactividad
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
     WHERE ae.PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND ae.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la asignacion actividad-estudiante solicitada' USING ERRCODE = 'P0002';
    END IF;

    IF academico_test.fn_actividad_asistencia_valida(v_pk_matricula, v_pk_tactividad, p_fecha) THEN
        RETURN;
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM academico_test.TASISTENCIA s
         WHERE s.FK_TMATRICULA = v_pk_matricula
           AND s.FECHA         = p_fecha
           AND s.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede observar: no hay asistencia registrada para esta actividad el %', p_fecha
            USING ERRCODE = '22023';
    END IF;

    RAISE EXCEPTION 'No se puede observar: el estudiante tiene una inasistencia injustificada registrada el %', p_fecha
        USING ERRCODE = '22023';
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_asistencia_assert_preescolar(BIGINT, DATE)
    IS 'Gate de asistencia para actividades FORMATIVAS (preescolar). V450: delega la regla en fn_actividad_asistencia_valida -- ese dia le tomaron asistencia al estudiante en CUALQUIER sesion y no es inasistencia injustificada. Antes (V243) exigia una fila con FK_TACTIVIDAD = la actividad, que V436 dejo de escribir al mandar a preescolar a la sesion por asignatura + bloque: el gate pedia una fila inalcanzable y observar quedaba bloqueado por el camino normal del docente. Mantiene los dos mensajes y el 22023 de V243: distingue "no hay asistencia registrada" de "inasistencia injustificada". V243/V450.';


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
                SELECT academico_test.fn_actividad_asistencia_fecha_resolver(
                           b.PK_TMATRICULA, c.pk_tactividad) AS fecha
            ) asi ON ae.PK_TACTIVIDAD_ESTUDIANTE IS NOT NULL
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

DROP FUNCTION IF EXISTS academico_test.fn_actividad_estudiantes_calificaciones_listar(
    BIGINT, BIGINT, DATE, VARCHAR);

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_estudiantes_calificaciones_listar(
    p_pk_usuario_solicitante  BIGINT,
    p_pk_tactividad           BIGINT,
    p_fecha                   DATE    DEFAULT CURRENT_DATE,
    p_search                  VARCHAR DEFAULT NULL
)
RETURNS TABLE (
    pk_tactividad_estudiante  BIGINT,
    pk_tmatricula             BIGINT,
    nombre_estudiante         VARCHAR,
    instrumento               VARCHAR,
    fecha                     DATE,
    pk_tasistencia            BIGINT,
    fk_tlv_tipo_asistencia    BIGINT,
    tipo_asistencia           VARCHAR,
    asistencia_observacion    VARCHAR,
    fk_soporte_archivo        BIGINT,
    calificacion              NUMERIC,
    calificable               CHAR(1),
    nota_observacion          VARCHAR,
    es_formativa              BOOLEAN,
    fecha_asistencia          DATE
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_pk_asignatura     BIGINT;
    v_instrumento       VARCHAR;
    v_es_formativa      BOOLEAN;
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', NULL, NULL, NULL, p_pk_tactividad
    );

    SELECT a.FK_TASIGNATURA, lv.VALOR
      INTO v_pk_asignatura, v_instrumento
      FROM academico_test.TACTIVIDAD a
      LEFT JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad AND a.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la actividad solicitada' USING ERRCODE = 'P0002';
    END IF;

    v_es_formativa := academico_test.fn_actividad_es_formativa(p_pk_tactividad);

    RETURN QUERY
    WITH base AS (
        SELECT ae.PK_TACTIVIDAD_ESTUDIANTE,
               ae.FK_TMATRICULA,
               NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                          u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO)), '')::VARCHAR AS nombre
          FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
          JOIN academico_test.TMATRICULA m   ON m.PK_TMATRICULA = ae.FK_TMATRICULA
          JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
          JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO = es.FK_TUSUARIO
         WHERE ae.FK_TACTIVIDAD = p_pk_tactividad
           AND ae.ACTIVE = TRUE
    )
    SELECT b.PK_TACTIVIDAD_ESTUDIANTE,
           b.FK_TMATRICULA,
           b.nombre,
           v_instrumento,
           p_fecha,
           s.PK_TASISTENCIA,
           s.FK_TLV_TIPO_ASISTENCIA,
           lva.NOMBRE::VARCHAR,
           s.OBSERVACION,
           s.FK_SOPORTE_ARCHIVO,
           n.CALIFICACION,
           n.CALIFICABLE,
           n.OBSERVACION,
           v_es_formativa,
           asi.FECHA
      FROM base b
      LEFT JOIN LATERAL (
          SELECT s2.PK_TASISTENCIA, s2.FK_TLV_TIPO_ASISTENCIA, s2.OBSERVACION, s2.FK_SOPORTE_ARCHIVO
            FROM academico_test.TASISTENCIA s2
           WHERE s2.FK_TMATRICULA = b.FK_TMATRICULA
             AND s2.FECHA         = p_fecha
             AND s2.ACTIVE = TRUE
             AND (v_es_formativa OR s2.FK_TASIGNATURA = v_pk_asignatura)
           ORDER BY s2.PK_TASISTENCIA DESC
           LIMIT 1
      ) s ON TRUE
      LEFT JOIN LATERAL (
          SELECT academico_test.fn_actividad_asistencia_fecha_resolver(
                     b.FK_TMATRICULA, p_pk_tactividad) AS FECHA
      ) asi ON TRUE
      LEFT JOIN academico_test.TLISTA_VALOR lva ON lva.PK_LISTA_VALOR = s.FK_TLV_TIPO_ASISTENCIA
      LEFT JOIN academico_test.TACTIVIDAD_NOTA n
             ON n.FK_TACTIVIDAD_ESTUDIANTE = b.PK_TACTIVIDAD_ESTUDIANTE AND n.ACTIVE = TRUE
     WHERE p_search IS NULL
        OR TRIM(p_search) = ''
        OR b.nombre ILIKE '%' || TRIM(p_search) || '%'
     ORDER BY b.nombre, b.PK_TACTIVIDAD_ESTUDIANTE;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_estudiantes_calificaciones_listar(BIGINT, BIGINT, DATE, VARCHAR)
    IS 'Tabla de la pantalla "Calificaciones: <actividad>": una fila por TACTIVIDAD_ESTUDIANTE ACTIVO con nombre, asistencia de p_fecha (solo lectura: NULL = sin registrar, no es error), nota e instrumento. V450 agrega es_formativa y fecha_asistencia, y corrige la llave con la que se resolvia la asistencia (antes siempre por asignatura, asi que en preescolar venia NULL aunque existiera). Ademas: en una actividad FORMATIVA la asistencia del dia ya no se filtra por llave --cualquier sesion de ese dia cuenta, ver fn_actividad_asistencia_valida-- y fecha_asistencia sale de fn_actividad_asistencia_fecha_resolver, el mismo helper que usa el gate. OJO: la columna `fecha` es el eco de p_fecha, NO una fecha con asistencia; para BODY.FECHA va fecha_asistencia. Gate VER sobre PLANEADOR. V227/V450.';

UPDATE public.query q
   SET detail = q.detail || ' V450 -- En las actividades FORMATIVAS, la asistencia que habilita observar ya no tiene que ser una fila con FK_TACTIVIDAD (V436 dejo de escribirlas): basta con que ESE dia se le haya tomado asistencia al estudiante en cualquier sesion y que no sea inasistencia injustificada. fechaAsistencia/tieneAsistencia se calculan con esa misma regla, compartida con el gate (fn_actividad_asistencia_valida / _fecha_resolver). Cada fila agrega ademas es_formativa (TRUE = se registra con OBSERVACION, no con nota) y fecha_asistencia (la fecha en la que ESE estudiante tiene una asistencia que el gate aceptaria; NULL = no se puede calificar ni observar todavia). OJO: la columna `fecha` sigue siendo el ECO de ?fecha= (default hoy) y NO sirve para BODY.FECHA: para eso va fecha_asistencia.'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   IN ('/planeador/planilla/calificaciones', '/planeador/actividades/:ID/calificaciones')
   AND q.http_method     = 'GET'
   AND q.detail NOT LIKE '%V450 --%';


UPDATE public.query q
   SET query = 'SELECT d.*,
       academico_test.fn_actividad_es_formativa(d.pk_tactividad) AS es_formativa
  FROM academico_test.fn_actividad_buscar_por_pk(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    COALESCE(CAST(:QUERY.DIAS_GRACIA AS INT), 2)
) d;',
       detail = q.detail || ' V450 -- Agrega es_formativa (fn_actividad_es_formativa, V243): TRUE = la actividad cuelga de una unidad con referente NO evaluativo (preescolar / "Proyecto Pedagogico") y se registra con OBSERVACION, no con nota -- fn_actividad_nota_calificar la rechaza con 22023. Es la MISMA columna que ya devuelve GET /planeador/planilla/columnas. NO se puede deducir en el cliente: una actividad evaluativa sin instrumento definido tambien llega con fk_tlv_instrumento_evaluacion NULL, y es_evaluativa es otro concepto (flag manual con DEFAULT S). Una actividad SIN unidad devuelve FALSE por decision explicita de V243.'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/actividades/:ID'
   AND q.http_method     = 'GET'
   AND q.detail NOT LIKE '%V450 --%';

UPDATE public.query q
   SET query = 'SELECT t.p || jsonb_build_object(
           ''esFormativa'',
           academico_test.fn_actividad_es_formativa((t.p->''actividad''->>''id'')::BIGINT)
       ) AS pantalla
  FROM (SELECT academico_test.fn_actividad_pantalla_edicion(
            public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
            CAST(:PARAM.ID AS BIGINT),
            COALESCE(CAST(:QUERY.DIAS_GRACIA AS INT), 2)
        ) AS p) t',
       detail = q.detail || ' V450 -- Agrega la clave esFormativa al DTO (fn_actividad_es_formativa, V243), con la misma semantica que es_formativa de GET /planeador/actividades/:ID y de GET /planeador/planilla/columnas: TRUE = la actividad se registra con OBSERVACION y no con nota.'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/actividades/:ID/pantalla-edicion'
   AND q.http_method     = 'GET'
   AND q.detail NOT LIKE '%V450 --%';

