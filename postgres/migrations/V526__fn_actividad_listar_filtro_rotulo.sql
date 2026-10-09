-- ===========================================================================
-- V526 — fn_actividad_listar_interno: filtro por pares (grado, asignatura)
-- de una pestaña de Rotulo de Ejecucion (V525), para acotar GET /planeador/
-- actividades/mias server-side sin romper el paginado.
-- Por que un par y no un grado solo: dos asignaturas del mismo grado pueden
-- resolver a rotulos distintos (V525). Por que VARCHAR[] y no JSONB: un
-- parametro QUERY.* de un GET siempre llega como String al binder, nunca
-- como List/array -- JSONB ahi rompe en runtime, mismo hallazgo que V253
-- para TEXT[]/VARCHAR[]. Cada elemento es "grado:asignatura" (asignatura
-- vacio = comodin), armado con string_to_array en el endpoint (V527).
-- Depende de: V481 (fn_actividad_listar_interno/_listar/_listar_docente),
-- V253 (mismo patron CSV-por-GET), V525.
-- ===========================================================================

SET search_path TO academico_test, public;

DROP FUNCTION IF EXISTS academico_test.fn_actividad_listar_docente(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, VARCHAR[], INT, VARCHAR, BOOLEAN, INT, INT, DATE);
DROP FUNCTION IF EXISTS academico_test.fn_actividad_listar(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, DATE, DATE, VARCHAR[], INT, BOOLEAN, VARCHAR, BOOLEAN, INT, INT, BIGINT, DATE);
DROP FUNCTION IF EXISTS academico_test.fn_actividad_listar_interno(BIGINT[], BOOLEAN, BOOLEAN, BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, DATE, DATE, VARCHAR[], INT, BOOLEAN, VARCHAR, BOOLEAN, INT, INT, BIGINT, DATE);
-- Version con el ultimo parametro JSONB (primera version de V526, antes de
-- descubrir que QUERY.* no admite array/objeto en un GET -- ver cabecera).
DROP FUNCTION IF EXISTS academico_test.fn_actividad_listar_docente(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, VARCHAR[], INT, VARCHAR, BOOLEAN, INT, INT, DATE, JSONB);
DROP FUNCTION IF EXISTS academico_test.fn_actividad_listar(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, DATE, DATE, VARCHAR[], INT, BOOLEAN, VARCHAR, BOOLEAN, INT, INT, BIGINT, DATE, JSONB);
DROP FUNCTION IF EXISTS academico_test.fn_actividad_listar_interno(BIGINT[], BOOLEAN, BOOLEAN, BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, DATE, DATE, VARCHAR[], INT, BOOLEAN, VARCHAR, BOOLEAN, INT, INT, BIGINT, DATE, JSONB);
-- Firmas previas a p_periodos_lectura / p_fk_tfuncionario (planeador de otro docente, V553).
DROP FUNCTION IF EXISTS academico_test.fn_actividad_listar_interno(BIGINT[], BOOLEAN, BOOLEAN, BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, DATE, DATE, VARCHAR[], INT, BOOLEAN, VARCHAR, BOOLEAN, INT, INT, BIGINT, DATE, VARCHAR[]);
DROP FUNCTION IF EXISTS academico_test.fn_actividad_listar_docente(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, VARCHAR[], INT, VARCHAR, BOOLEAN, INT, INT, DATE, VARCHAR[]);

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
    p_dia                      DATE      DEFAULT NULL,
    p_grado_asignatura_pares   VARCHAR[] DEFAULT NULL,
    p_periodos_lectura         BIGINT[]  DEFAULT NULL
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
          -- V526: grado efectivo (via grupo, o si no tiene, via su unidad) --
          -- mismo criterio de resolucion que el SELECT final de abajo
          -- (COALESCE(g.FK_TGRADO, u.FK_TGRADO)) -- para filtrar por pestaña
          -- sin duplicar la logica de resolucion.
          LEFT JOIN academico_test.TGRUPO g_ga  ON g_ga.PK_TGRUPO = a.FK_TGRUPO
          LEFT JOIN academico_test.TUNIDAD u_ga ON u_ga.PK_TUNIDAD = a.FK_TUNIDAD
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
                                 OR pa_sc.FK_TSEDE = ANY(p_sedes_lectura))
                            AND (p_periodos_lectura IS NULL
                                 OR pa_sc.PK_TPERIODO_ACADEMICO = ANY(p_periodos_lectura)))
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
                                 OR pa_sc.FK_TSEDE = ANY(p_sedes_lectura))
                            AND (p_periodos_lectura IS NULL
                                 OR pa_sc.PK_TPERIODO_ACADEMICO = ANY(p_periodos_lectura)))
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
           -- V526: pestaña de Rotulo de Ejecucion activa. Cada elemento es
           -- "grado:asignatura" (asignatura vacío = comodín) -- ver cabecera.
           AND (p_grado_asignatura_pares IS NULL OR EXISTS (
                   SELECT 1
                     FROM unnest(p_grado_asignatura_pares) AS par(valor)
                    WHERE split_part(par.valor, ':', 1)::BIGINT = COALESCE(g_ga.FK_TGRADO, u_ga.FK_TGRADO)
                      AND (
                            split_part(par.valor, ':', 2) = ''
                         OR split_part(par.valor, ':', 2)::BIGINT = a.FK_TASIGNATURA
                      )
               ))
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
           COALESCE(b.total, 0),
           -- Regla 13: Rotulo de Ejecucion del referente que aplica al grado
           -- de la actividad (grupo o, si no tiene, el de su unidad) y su
           -- asignatura.
           COALESCE(
               (SELECT rc_rot.ROTULO_EJECUCION
                  FROM academico_test.TREFERENTE_CURRICULAR rc_rot
                 WHERE rc_rot.PK_REFERENTE_CURRICULAR =
                       academico_test.fn_unidad_referente_aplicable(gr.PK_TGRADO, a.FK_TASIGNATURA)),
               'Actividad'
           )::VARCHAR
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

COMMENT ON FUNCTION academico_test.fn_actividad_listar_interno(BIGINT[], BOOLEAN, BOOLEAN, BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, DATE, DATE, VARCHAR[], INT, BOOLEAN, VARCHAR, BOOLEAN, INT, INT, BIGINT, DATE, VARCHAR[], BIGINT[])
    IS 'INTERNO: página de actividades del Planeador sin gate; recibe el alcance ya resuelto (fn_planeador_listado_alcance). Lo reutilizan fn_actividad_listar (GET /planeador/actividades y su export) y fn_actividad_listar_docente (GET /planeador/actividades/mias). ALCANCE: grupo o unidad en una sede de lectura (o alcance total); huérfanas (sin grupo ni unidad) solo para su autor; docente puro (p_solo_propias) solo lo que dicta vía TDOCENTE_ASIGNATURA más sus huérfanas. p_fk_tfuncionario filtra por el docente que DICTA la actividad (no el autor de la unidad) y deja fuera las que no tienen grupo. p_search matchea título+descripción (índice trigram), nivel de enseñanza de la unidad o nombre del instrumento. p_estados filtra por el estado derivado (fn_actividad_estado) con p_dias_gracia. p_dia: solo las actividades cuya ventana [FECHA_INICIO, FECHA_CIERRE] cubre ese día; dia_anterior/dia_siguiente son el día ocupado más cercano a cada lado, saltando los vacíos; un día vacío devuelve UNA fila con la actividad en NULL, total_count = 0 y las flechas. p_grado_asignatura_pares (V526): acota a una pestaña de Rotulo de Ejecucion -- VARCHAR[] de "grado:asignatura" (asignatura vacío = comodín), nunca JSONB (QUERY.* de un GET no admite array/objeto). p_periodos_lectura (fn_planeador_alcance_docente): si no es NULL, el grupo o la unidad además tiene que estar en uno de esos periodos académicos (alcance sede+jornada del coordinador). Orden por whitelist fecha_inicio|fecha_cierre|fecha_creacion|titulo|ponderacion. total_count via COUNT(*) OVER().';

-- ---------------------------------------------------------------------------
-- Wrappers: agregan p_grado_asignatura_pares al final y lo pasan tal cual.
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
    p_dia                      DATE      DEFAULT NULL,
    p_grado_asignatura_pares   VARCHAR[] DEFAULT NULL
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

    SELECT * INTO v_alc FROM academico_test.fn_planeador_alcance_docente(p_pk_usuario_solicitante);

    RETURN QUERY
    SELECT * FROM academico_test.fn_actividad_listar_interno(
        v_alc.sedes_lectura, v_alc.alcance_total, v_alc.solo_propias, v_alc.fk_tfuncionario_propio,
        p_pk_usuario_solicitante::VARCHAR,
        p_search, p_fk_tasignatura, p_fk_tgrupo, p_fk_tunidad,
        p_fk_tlv_tipo_actividad, p_fk_tlv_instrumento, p_fecha_desde, p_fecha_hasta,
        p_estados, p_dias_gracia, p_incluir_inactivas,
        p_orden_por, p_orden_asc, p_limite, p_offset, p_fk_tfuncionario, p_dia,
        p_grado_asignatura_pares, v_alc.periodos_lectura
    );
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_listar(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, DATE, DATE, VARCHAR[], INT, BOOLEAN, VARCHAR, BOOLEAN, INT, INT, BIGINT, DATE, VARCHAR[])
    IS 'GET /planeador/actividades y POST /planeador/actividades/export-all: gate VER sobre PLANEADOR, alcance del usuario (fn_planeador_alcance_docente: sedes y, en nivel 3, pares sede+jornada) y delega en fn_actividad_listar_interno, que documenta filtros, orden y paginado por día. Devuelve t_actividad_listado_fila, la misma fila que /planeador/actividades/mias.';

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
    p_dia                      DATE      DEFAULT NULL,
    p_grado_asignatura_pares   VARCHAR[] DEFAULT NULL,
    p_fk_tfuncionario          BIGINT    DEFAULT NULL
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

    SELECT * INTO v_alc
      FROM academico_test.fn_planeador_alcance_docente(p_pk_usuario_solicitante, p_fk_tfuncionario);

    -- Docente puro sin funcionario, o alcance total sin docente elegido: 0
    -- filas. Delegar con el filtro en NULL devolvería todo su alcance.
    IF v_alc.fk_tfuncionario IS NULL AND (v_alc.solo_propias OR v_alc.alcance_total) THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT * FROM academico_test.fn_actividad_listar_interno(
        v_alc.sedes_lectura, v_alc.alcance_total, v_alc.solo_propias, v_alc.fk_tfuncionario_propio,
        p_pk_usuario_solicitante::VARCHAR,
        p_search, p_fk_tasignatura, p_fk_tgrupo, p_fk_tunidad,
        NULL, NULL, NULL, NULL,
        p_estados, p_dias_gracia, FALSE,
        p_orden_por, p_orden_asc, p_limite, p_offset, v_alc.fk_tfuncionario, p_dia,
        p_grado_asignatura_pares, v_alc.periodos_lectura
    );
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_listar_docente(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, VARCHAR[], INT, VARCHAR, BOOLEAN, INT, INT, DATE, VARCHAR[], BIGINT)
    IS 'GET /planeador/actividades/mias: gate VER sobre PLANEADOR y las actividades que DICTA el docente resuelto por fn_planeador_alcance_docente, vía fn_actividad_listar_interno. Docente puro: las suyas (ignora p_fk_tfuncionario; sin funcionario, 0 filas). Otros con p_fk_tfuncionario (?funcionario=): las de ese docente dentro del alcance, 42501 si no dicta nada en él. Otros sin él: todo su alcance (nivel 3: sus pares sede+jornada); alcance total sin docente elegido: 0 filas. Solo activas; sin filtros de tipo, instrumento ni fechas. p_grado_asignatura_pares (V526): acota a una pestaña de Rotulo de Ejecucion (fn_planeador_actividad_tabs_listar, V525) -- VARCHAR[] de "grado:asignatura", nunca JSONB. Devuelve t_actividad_listado_fila, la misma fila que GET /planeador/actividades.';
