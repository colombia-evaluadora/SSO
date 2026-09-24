-- ===========================================================================
-- V481 — Listado de actividades del Planeador en piezas: tipo de fila,
-- alcance, progreso, núcleo sin gate y dos wrappers (general y "mías").
-- La fila trae ES_FORMATIVA: el front oculta "Aprobar" (calificación en
-- bloque) en las actividades formativas.
-- Los dos wrappers devuelven SETOF t_actividad_listado_fila: una columna
-- nueva se agrega UNA vez (ALTER TYPE ... ADD ATTRIBUTE + el SELECT del
-- núcleo) y llega a los dos endpoints; con RETURNS TABLE en cada uno, el
-- de "mías" se quedaba con la forma vieja y respondía 42804.
-- Depende de: V29 (alcance por sede/rol), V224 (fn_actividad_estado,
-- fn_funcionario_actual), V454 (versión previa), V475/V476
-- (fn_actividad_es_formativa).
-- ===========================================================================

SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- 1. Fila del listado.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF to_regtype('academico_test.t_actividad_listado_fila') IS NULL THEN
        CREATE TYPE academico_test.t_actividad_listado_fila AS (
            pk_tactividad                   BIGINT,
            titulo                          VARCHAR,
            descripcion                     VARCHAR,
            fk_tasignatura                  BIGINT,
            asignatura                      VARCHAR,
            fk_tarea                        BIGINT,
            area                            VARCHAR,
            fk_tunidad                      BIGINT,
            unidad                          VARCHAR,
            fk_tgrupo                       BIGINT,
            grupo                           VARCHAR,
            fk_tgrado                       BIGINT,
            grado                           VARCHAR,
            grado_codigo                    VARCHAR,
            grado_grupo                     VARCHAR,
            fk_tlv_tipo_actividad           BIGINT,
            tipo_actividad                  VARCHAR,
            fk_tlv_instrumento_evaluacion   BIGINT,
            instrumento_evaluacion          VARCHAR,
            ponderacion                     NUMERIC,
            influencia                      NUMERIC,
            es_evaluativa                   VARCHAR,
            es_recuperacion                 VARCHAR,
            es_formativa                    BOOLEAN,
            fecha_inicio                    DATE,
            fecha_cierre                    DATE,
            fecha_calificado                DATE,
            estado                          VARCHAR,
            estudiantes_asignados           BIGINT,
            estudiantes_evaluados           BIGINT,
            porcentaje_evaluado             NUMERIC,
            active                          BOOLEAN,
            dia                             DATE,
            dia_anterior                    DATE,
            dia_siguiente                   DATE,
            total_count                     BIGINT
        );
    END IF;
END $$;

COMMENT ON TYPE academico_test.t_actividad_listado_fila
    IS 'Fila de GET /planeador/actividades, /planeador/actividades/mias y su export. Una columna nueva: ALTER TYPE ... ADD ATTRIBUTE y agregarla al SELECT de fn_actividad_listar_interno.';

-- ---------------------------------------------------------------------------
-- 2. Alcance de lectura del Planeador, resuelto una vez por petición.
--    Lo comparten los listados de actividades y de unidades.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_planeador_listado_alcance(
    p_pk_usuario_solicitante BIGINT
)
RETURNS TABLE (
    sedes_lectura   BIGINT[],
    alcance_total   BOOLEAN,
    solo_propias    BOOLEAN,
    fk_tfuncionario BIGINT
)
LANGUAGE sql
STABLE
AS $$
    SELECT ARRAY(SELECT sl.sede_id
                   FROM academico_test.fn_usuario_sedes_lectura(p_pk_usuario_solicitante) sl),
           COALESCE(academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario_solicitante), 99) <= 1,
           academico_test.fn_usuario_es_docente_puro(p_pk_usuario_solicitante),
           academico_test.fn_funcionario_actual(p_pk_usuario_solicitante);
$$;

COMMENT ON FUNCTION academico_test.fn_planeador_listado_alcance(BIGINT)
    IS 'INTERNO: alcance de lectura de un usuario en los listados del Planeador. sedes_lectura (fn_usuario_sedes_lectura); alcance_total = nivel de rol 0-1 (ve todas las sedes); solo_propias = docente puro (solo lo que dicta o creó); fk_tfuncionario = su funcionario (fn_funcionario_actual). Lo usan los wrappers de fn_actividad_listar_interno y fn_unidad_listar_interno, para que los listados no resuelvan el alcance cada uno a su manera. No valida permisos.';

-- ---------------------------------------------------------------------------
-- 3. Progreso de evaluación de una actividad.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_progreso_evaluacion(
    p_pk_tactividad BIGINT
)
RETURNS TABLE (
    asignados  BIGINT,
    evaluados  BIGINT,
    porcentaje NUMERIC
)
LANGUAGE sql
STABLE
AS $$
    -- Evaluado = con nota, o con OBSERVACION y CALIFICABLE='N' (formativa /
    -- preescolar): la misma regla que fn_actividad_finalizacion_refrescar.
    SELECT t.asignados,
           t.evaluados,
           CASE WHEN t.asignados > 0
                THEN ROUND(t.evaluados * 100.0 / t.asignados, 2)
                ELSE 0 END
      FROM (
        SELECT COUNT(*)::BIGINT AS asignados,
               COUNT(*) FILTER (
                   WHERE COALESCE(n.DEFINITIVA, n.CALIFICACION) IS NOT NULL
                      OR (n.CALIFICABLE = 'N' AND NULLIF(TRIM(n.OBSERVACION), '') IS NOT NULL)
               )::BIGINT AS evaluados
          FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
          LEFT JOIN academico_test.TACTIVIDAD_NOTA n
                 ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                AND n.ACTIVE = TRUE
         WHERE ae.FK_TACTIVIDAD = p_pk_tactividad
           AND ae.ACTIVE = TRUE
      ) t;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_progreso_evaluacion(BIGINT)
    IS 'INTERNO: estudiantes asignados, evaluados y % evaluado de una actividad. Evaluado = con nota, o con observación y CALIFICABLE = N (formativa). Lo usa fn_actividad_listar_interno por cada fila de la página.';

-- ---------------------------------------------------------------------------
-- 4. Núcleo sin gate. Recibe el alcance ya resuelto.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_actividad_listar_docente(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, VARCHAR[], INT, VARCHAR, BOOLEAN, INT, INT, DATE);
DROP FUNCTION IF EXISTS academico_test.fn_actividad_listar(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, DATE, DATE, VARCHAR[], INT, BOOLEAN, VARCHAR, BOOLEAN, INT, INT, BIGINT, DATE);

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_listar_interno(
    -- Alcance (fn_planeador_listado_alcance) y quién pide, para las
    -- actividades huérfanas (sin grupo ni unidad), que solo ve su autor.
    p_sedes_lectura            BIGINT[],
    p_alcance_total            BOOLEAN,
    p_solo_propias             BOOLEAN,
    p_fk_tfuncionario_propio   BIGINT,
    p_creado_por               VARCHAR,
    -- Filtros.
    p_search                   VARCHAR   DEFAULT NULL,
    p_fk_tasignatura           BIGINT    DEFAULT NULL,
    p_fk_tgrupo                BIGINT    DEFAULT NULL,
    p_fk_tunidad               BIGINT    DEFAULT NULL,
    p_fk_tlv_tipo_actividad    BIGINT    DEFAULT NULL,
    p_fk_tlv_instrumento       BIGINT    DEFAULT NULL,
    p_fecha_desde              DATE      DEFAULT NULL,
    p_fecha_hasta              DATE      DEFAULT NULL,
    p_estados                  VARCHAR[] DEFAULT NULL,
    p_dias_gracia              INT       DEFAULT 2,
    p_incluir_inactivas        BOOLEAN   DEFAULT FALSE,
    p_orden_por                VARCHAR   DEFAULT 'fecha_inicio',
    p_orden_asc                BOOLEAN   DEFAULT TRUE,
    p_limite                   INT       DEFAULT 20,
    p_offset                   INT       DEFAULT 0,
    p_fk_tfuncionario          BIGINT    DEFAULT NULL,
    p_dia                      DATE      DEFAULT NULL
)
RETURNS SETOF academico_test.t_actividad_listado_fila
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_hoy  DATE := CURRENT_DATE;
    v_key  VARCHAR;
BEGIN
    v_key := LOWER(TRIM(COALESCE(p_orden_por, 'fecha_inicio')));
    IF v_key NOT IN ('fecha_inicio','fecha_cierre','fecha_creacion','titulo','ponderacion') THEN
        v_key := 'fecha_inicio';
    END IF;

    RETURN QUERY
    WITH universo AS (
        SELECT a.PK_TACTIVIDAD  AS pk,
               a.FECHA_INICIO   AS fi,
               a.FECHA_CIERRE   AS fc,
               a.FECHA_CREACION AS fcr,
               a.TITULO         AS titulo,
               a.PONDERACION    AS pond
          FROM academico_test.TACTIVIDAD a
         WHERE (p_incluir_inactivas OR a.ACTIVE = TRUE)
           AND (
                 EXISTS (SELECT 1
                           FROM academico_test.TGRUPO g_sc
                           JOIN academico_test.TGRADO gr_sc
                             ON gr_sc.PK_TGRADO = g_sc.FK_TGRADO
                           JOIN academico_test.TPERIODO_ACADEMICO pa_sc
                             ON pa_sc.PK_TPERIODO_ACADEMICO = gr_sc.FK_TPERIODO_ACADEMICO
                           JOIN academico_test.TSEDE s_sc
                             ON s_sc.PK_TSEDE = pa_sc.FK_TSEDE AND s_sc.ACTIVE = TRUE
                          WHERE g_sc.PK_TGRUPO = a.FK_TGRUPO
                            AND (p_alcance_total
                                 OR pa_sc.FK_TSEDE = ANY(p_sedes_lectura)))
              OR EXISTS (SELECT 1
                           FROM academico_test.TUNIDAD u_sc
                           JOIN academico_test.TGRADO gr_sc
                             ON gr_sc.PK_TGRADO = u_sc.FK_TGRADO
                           JOIN academico_test.TPERIODO_ACADEMICO pa_sc
                             ON pa_sc.PK_TPERIODO_ACADEMICO = gr_sc.FK_TPERIODO_ACADEMICO
                           JOIN academico_test.TSEDE s_sc
                             ON s_sc.PK_TSEDE = pa_sc.FK_TSEDE AND s_sc.ACTIVE = TRUE
                          WHERE u_sc.PK_TUNIDAD = a.FK_TUNIDAD
                            AND (p_alcance_total
                                 OR pa_sc.FK_TSEDE = ANY(p_sedes_lectura)))
              OR (a.FK_TGRUPO IS NULL AND a.FK_TUNIDAD IS NULL
                  AND (p_alcance_total OR a.CREATED_BY = p_creado_por))
               )
           AND (p_fk_tasignatura        IS NULL OR a.FK_TASIGNATURA = p_fk_tasignatura)
           AND (p_fk_tgrupo             IS NULL OR a.FK_TGRUPO = p_fk_tgrupo)
           AND (p_fk_tunidad            IS NULL OR a.FK_TUNIDAD = p_fk_tunidad)
           AND (p_fk_tfuncionario       IS NULL OR EXISTS (
                    SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA da
                     WHERE da.FK_TGRUPO       = a.FK_TGRUPO
                       AND da.FK_TASIGNATURA  = a.FK_TASIGNATURA
                       AND da.FK_TFUNCIONARIO = p_fk_tfuncionario
                       AND da.ACTIVE = TRUE))
           -- Docente puro: lo que dicta, más sus huérfanas.
           AND (NOT p_solo_propias
                OR EXISTS (SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA da
                            WHERE da.FK_TGRUPO       = a.FK_TGRUPO
                              AND da.FK_TASIGNATURA  = a.FK_TASIGNATURA
                              AND da.FK_TFUNCIONARIO = p_fk_tfuncionario_propio
                              AND da.ACTIVE = TRUE)
                OR (a.FK_TGRUPO IS NULL AND a.FK_TUNIDAD IS NULL
                    AND a.CREATED_BY = p_creado_por))
           AND (p_fk_tlv_tipo_actividad IS NULL OR a.FK_TLV_TIPO_ACTIVIDAD = p_fk_tlv_tipo_actividad)
           AND (p_fk_tlv_instrumento    IS NULL OR a.FK_TLV_INSTRUMENTO_EVALUACION = p_fk_tlv_instrumento)
           AND (p_fecha_desde IS NULL OR COALESCE(a.FECHA_CIERRE, a.FECHA_INICIO) >= p_fecha_desde)
           AND (p_fecha_hasta IS NULL OR COALESCE(a.FECHA_INICIO, a.FECHA_CIERRE) <= p_fecha_hasta)
           -- La expresión de título+descripción es idéntica a la de
           -- idx_tactividad_busqueda_trgm: si cambia, el índice deja de usarse.
           AND (p_search IS NULL
                OR (COALESCE(a.TITULO,'') || ' ' || COALESCE(a.DESCRIPCION,''))
                       ILIKE '%' || p_search || '%'
                OR EXISTS (
                       SELECT 1
                         FROM academico_test.TUNIDAD u2
                         JOIN academico_test.TGRADO g2            ON g2.PK_TGRADO = u2.FK_TGRADO
                         JOIN academico_test.TNIVEL_ENSENANZA ne2 ON ne2.PK_NIVEL_ENSENANZA = g2.FK_TNIVEL_ENSENANZA
                        WHERE u2.PK_TUNIDAD = a.FK_TUNIDAD
                          AND ne2.NOMBRE ILIKE '%' || p_search || '%')
                OR EXISTS (
                       SELECT 1
                         FROM academico_test.TLISTA_VALOR lvs
                        WHERE lvs.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
                          AND lvs.NOMBRE ILIKE '%' || p_search || '%'))
           AND (p_estados IS NULL OR academico_test.fn_actividad_estado(
                    a.FECHA_INICIO, a.FECHA_CIERRE, a.FECHA_CALIFICADO, v_hoy, p_dias_gracia
                ) = ANY(p_estados))
    ),
    del_dia AS (
        SELECT u.*
          FROM universo u
         WHERE p_dia IS NULL
            OR ((u.fi IS NOT NULL OR u.fc IS NOT NULL)
                AND (u.fi IS NULL OR u.fi <= p_dia)
                AND (u.fc IS NULL OR u.fc >= p_dia))
    ),
    -- Las flechas miran el universo SIN el filtro por día y saltan los días
    -- vacíos. HAVING deja una fila aunque no haya actividades: es la que le
    -- permite al cliente salir de un día vacío.
    nav AS (
        SELECT MAX(CASE WHEN u.fc IS NOT NULL AND u.fc < p_dia THEN u.fc
                        WHEN u.fi IS NOT NULL AND u.fi < p_dia THEN p_dia - 1
                   END) AS anterior,
               MIN(CASE WHEN u.fi IS NOT NULL AND u.fi > p_dia THEN u.fi
                        WHEN u.fc IS NOT NULL AND u.fc > p_dia THEN p_dia + 1
                   END) AS siguiente
          FROM universo u
         WHERE p_dia IS NOT NULL
        HAVING p_dia IS NOT NULL
    ),
    base AS (
        SELECT d.pk,
               COUNT(*) OVER() AS total
          FROM del_dia d
         ORDER BY
           CASE WHEN     p_orden_asc AND v_key = 'fecha_inicio'   THEN d.fi     END ASC  NULLS LAST,
           CASE WHEN NOT p_orden_asc AND v_key = 'fecha_inicio'   THEN d.fi     END DESC NULLS LAST,
           CASE WHEN     p_orden_asc AND v_key = 'fecha_cierre'   THEN d.fc     END ASC  NULLS LAST,
           CASE WHEN NOT p_orden_asc AND v_key = 'fecha_cierre'   THEN d.fc     END DESC NULLS LAST,
           CASE WHEN     p_orden_asc AND v_key = 'fecha_creacion' THEN d.fcr    END ASC  NULLS LAST,
           CASE WHEN NOT p_orden_asc AND v_key = 'fecha_creacion' THEN d.fcr    END DESC NULLS LAST,
           CASE WHEN     p_orden_asc AND v_key = 'titulo'         THEN d.titulo END ASC  NULLS LAST,
           CASE WHEN NOT p_orden_asc AND v_key = 'titulo'         THEN d.titulo END DESC NULLS LAST,
           CASE WHEN     p_orden_asc AND v_key = 'ponderacion'    THEN d.pond   END ASC  NULLS LAST,
           CASE WHEN NOT p_orden_asc AND v_key = 'ponderacion'    THEN d.pond   END DESC NULLS LAST,
           d.pk
         LIMIT CASE WHEN p_limite IS NULL THEN NULL ELSE GREATEST(p_limite, 1) END
        OFFSET GREATEST(COALESCE(p_offset, 0), 0)
    )
    SELECT a.PK_TACTIVIDAD,
           a.TITULO,
           a.DESCRIPCION,
           a.FK_TASIGNATURA,
           asig.NOMBRE,
           asig.FK_TAREA,
           ar.NOMBRE,
           a.FK_TUNIDAD,
           u.NOMBRE,
           a.FK_TGRUPO,
           g.NOMBRE,
           gr.PK_TGRADO,
           gr.NOMBRE,
           gr.CODIGO,
           academico_test.fn_grado_grupo_etiqueta(gr.NOMBRE, gr.CODIGO, g.NOMBRE),
           a.FK_TLV_TIPO_ACTIVIDAD,
           lvt.NOMBRE,
           a.FK_TLV_INSTRUMENTO_EVALUACION,
           lvi.NOMBRE,
           a.PONDERACION,
           a.INFLUENCIA,
           a.ES_EVALUATIVA::VARCHAR,
           a.ES_RECUPERACION::VARCHAR,
           academico_test.fn_actividad_es_formativa(a.PK_TACTIVIDAD),
           a.FECHA_INICIO,
           a.FECHA_CIERRE,
           a.FECHA_CALIFICADO,
           academico_test.fn_actividad_estado(a.FECHA_INICIO, a.FECHA_CIERRE, a.FECHA_CALIFICADO, v_hoy, p_dias_gracia),
           prog.asignados,
           prog.evaluados,
           prog.porcentaje,
           a.ACTIVE,
           p_dia,
           n.anterior,
           n.siguiente,
           COALESCE(b.total, 0)
      FROM base b
      FULL OUTER JOIN nav n ON TRUE
      LEFT JOIN academico_test.TACTIVIDAD a      ON a.PK_TACTIVIDAD = b.pk
      LEFT JOIN academico_test.TASIGNATURA asig  ON asig.PK_TASIGNATURA = a.FK_TASIGNATURA
      LEFT JOIN academico_test.TAREA ar          ON ar.PK_TAREA = asig.FK_TAREA
      LEFT JOIN academico_test.TUNIDAD u         ON u.PK_TUNIDAD = a.FK_TUNIDAD
      LEFT JOIN academico_test.TGRUPO g          ON g.PK_TGRUPO = a.FK_TGRUPO
      LEFT JOIN academico_test.TGRADO gr         ON gr.PK_TGRADO = COALESCE(g.FK_TGRADO, u.FK_TGRADO)
      LEFT JOIN academico_test.TLISTA_VALOR lvt  ON lvt.PK_LISTA_VALOR = a.FK_TLV_TIPO_ACTIVIDAD
      LEFT JOIN academico_test.TLISTA_VALOR lvi  ON lvi.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
      LEFT JOIN LATERAL academico_test.fn_actividad_progreso_evaluacion(a.PK_TACTIVIDAD) prog ON TRUE
     ORDER BY
       CASE WHEN     p_orden_asc AND v_key = 'fecha_inicio'   THEN a.FECHA_INICIO   END ASC  NULLS LAST,
       CASE WHEN NOT p_orden_asc AND v_key = 'fecha_inicio'   THEN a.FECHA_INICIO   END DESC NULLS LAST,
       CASE WHEN     p_orden_asc AND v_key = 'fecha_cierre'   THEN a.FECHA_CIERRE   END ASC  NULLS LAST,
       CASE WHEN NOT p_orden_asc AND v_key = 'fecha_cierre'   THEN a.FECHA_CIERRE   END DESC NULLS LAST,
       CASE WHEN     p_orden_asc AND v_key = 'fecha_creacion' THEN a.FECHA_CREACION END ASC  NULLS LAST,
       CASE WHEN NOT p_orden_asc AND v_key = 'fecha_creacion' THEN a.FECHA_CREACION END DESC NULLS LAST,
       CASE WHEN     p_orden_asc AND v_key = 'titulo'         THEN a.TITULO         END ASC  NULLS LAST,
       CASE WHEN NOT p_orden_asc AND v_key = 'titulo'         THEN a.TITULO         END DESC NULLS LAST,
       CASE WHEN     p_orden_asc AND v_key = 'ponderacion'    THEN a.PONDERACION    END ASC  NULLS LAST,
       CASE WHEN NOT p_orden_asc AND v_key = 'ponderacion'    THEN a.PONDERACION    END DESC NULLS LAST,
       a.PK_TACTIVIDAD;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_listar_interno(BIGINT[], BOOLEAN, BOOLEAN, BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, DATE, DATE, VARCHAR[], INT, BOOLEAN, VARCHAR, BOOLEAN, INT, INT, BIGINT, DATE)
    IS 'INTERNO: página de actividades del Planeador sin gate; recibe el alcance ya resuelto (fn_planeador_listado_alcance). Lo reutilizan fn_actividad_listar (GET /planeador/actividades y su export) y fn_actividad_listar_docente (GET /planeador/actividades/mias). ALCANCE: grupo o unidad en una sede de lectura (o alcance total); huérfanas (sin grupo ni unidad) solo para su autor; docente puro (p_solo_propias) solo lo que dicta vía TDOCENTE_ASIGNATURA más sus huérfanas. p_fk_tfuncionario filtra por el docente que DICTA la actividad (no el autor de la unidad) y deja fuera las que no tienen grupo. p_search matchea título+descripción (índice trigram), nivel de enseñanza de la unidad o nombre del instrumento. p_estados filtra por el estado derivado (fn_actividad_estado) con p_dias_gracia. p_dia: solo las actividades cuya ventana [FECHA_INICIO, FECHA_CIERRE] cubre ese día; dia_anterior/dia_siguiente son el día ocupado más cercano a cada lado, saltando los vacíos; un día vacío devuelve UNA fila con la actividad en NULL, total_count = 0 y las flechas. Orden por whitelist fecha_inicio|fecha_cierre|fecha_creacion|titulo|ponderacion. total_count via COUNT(*) OVER().';

-- ---------------------------------------------------------------------------
-- 5. Wrappers: gate + alcance + delegar.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_listar(
    p_pk_usuario_solicitante   BIGINT,
    p_search                   VARCHAR   DEFAULT NULL,
    p_fk_tasignatura           BIGINT    DEFAULT NULL,
    p_fk_tgrupo                BIGINT    DEFAULT NULL,
    p_fk_tunidad               BIGINT    DEFAULT NULL,
    p_fk_tlv_tipo_actividad    BIGINT    DEFAULT NULL,
    p_fk_tlv_instrumento       BIGINT    DEFAULT NULL,
    p_fecha_desde              DATE      DEFAULT NULL,
    p_fecha_hasta              DATE      DEFAULT NULL,
    p_estados                  VARCHAR[] DEFAULT NULL,
    p_dias_gracia              INT       DEFAULT 2,
    p_incluir_inactivas        BOOLEAN   DEFAULT FALSE,
    p_orden_por                VARCHAR   DEFAULT 'fecha_inicio',
    p_orden_asc                BOOLEAN   DEFAULT TRUE,
    p_limite                   INT       DEFAULT 20,
    p_offset                   INT       DEFAULT 0,
    p_fk_tfuncionario          BIGINT    DEFAULT NULL,
    p_dia                      DATE      DEFAULT NULL
)
RETURNS SETOF academico_test.t_actividad_listado_fila
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_alc RECORD;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    SELECT * INTO v_alc FROM academico_test.fn_planeador_listado_alcance(p_pk_usuario_solicitante);

    RETURN QUERY
    SELECT * FROM academico_test.fn_actividad_listar_interno(
        v_alc.sedes_lectura, v_alc.alcance_total, v_alc.solo_propias, v_alc.fk_tfuncionario,
        p_pk_usuario_solicitante::VARCHAR,
        p_search, p_fk_tasignatura, p_fk_tgrupo, p_fk_tunidad,
        p_fk_tlv_tipo_actividad, p_fk_tlv_instrumento, p_fecha_desde, p_fecha_hasta,
        p_estados, p_dias_gracia, p_incluir_inactivas,
        p_orden_por, p_orden_asc, p_limite, p_offset, p_fk_tfuncionario, p_dia
    );
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_listar(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, DATE, DATE, VARCHAR[], INT, BOOLEAN, VARCHAR, BOOLEAN, INT, INT, BIGINT, DATE)
    IS 'GET /planeador/actividades y POST /planeador/actividades/export-all: gate VER sobre PLANEADOR, alcance del usuario (fn_planeador_listado_alcance) y delega en fn_actividad_listar_interno, que documenta filtros, orden y paginado por día. Devuelve t_actividad_listado_fila, la misma fila que /planeador/actividades/mias.';

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_listar_docente(
    p_pk_usuario_solicitante   BIGINT,
    p_search                   VARCHAR   DEFAULT NULL,
    p_fk_tasignatura           BIGINT    DEFAULT NULL,
    p_fk_tgrupo                BIGINT    DEFAULT NULL,
    p_fk_tunidad               BIGINT    DEFAULT NULL,
    p_estados                  VARCHAR[] DEFAULT NULL,
    p_dias_gracia              INT       DEFAULT 2,
    p_orden_por                VARCHAR   DEFAULT 'fecha_inicio',
    p_orden_asc                BOOLEAN   DEFAULT TRUE,
    p_limite                   INT       DEFAULT 20,
    p_offset                   INT       DEFAULT 0,
    p_dia                      DATE      DEFAULT NULL
)
RETURNS SETOF academico_test.t_actividad_listado_fila
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_alc RECORD;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    SELECT * INTO v_alc FROM academico_test.fn_planeador_listado_alcance(p_pk_usuario_solicitante);

    -- Sin funcionario no hay "mías": 0 filas. Delegar con el filtro en NULL
    -- lo leería el núcleo como "sin filtro" y devolvería todo su alcance.
    IF v_alc.fk_tfuncionario IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT * FROM academico_test.fn_actividad_listar_interno(
        v_alc.sedes_lectura, v_alc.alcance_total, v_alc.solo_propias, v_alc.fk_tfuncionario,
        p_pk_usuario_solicitante::VARCHAR,
        p_search, p_fk_tasignatura, p_fk_tgrupo, p_fk_tunidad,
        NULL, NULL, NULL, NULL,
        p_estados, p_dias_gracia, FALSE,
        p_orden_por, p_orden_asc, p_limite, p_offset, v_alc.fk_tfuncionario, p_dia
    );
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_listar_docente(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, VARCHAR[], INT, VARCHAR, BOOLEAN, INT, INT, DATE)
    IS 'GET /planeador/actividades/mias: gate VER sobre PLANEADOR y las actividades que DICTA el funcionario del usuario autenticado (fn_funcionario_actual), vía fn_actividad_listar_interno con p_fk_tfuncionario fijado; sin funcionario, 0 filas. Solo activas; sin filtros de tipo, instrumento ni fechas. Devuelve t_actividad_listado_fila, la misma fila que GET /planeador/actividades.';
