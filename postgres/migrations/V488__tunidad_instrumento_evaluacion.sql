-- ===========================================================================
-- V488 — Instrumento de la unidad DERIVADO de sus actividades, y listado /
-- detalle de unidad en piezas: tipo de fila, núcleo sin gate y wrapper.
-- El panel titula "Actividades en {instrumento}" con el instrumento que
-- comparten sus actividades; no es un dato que el docente capture en la
-- unidad, así que TUNIDAD no lleva columna para él (se retira si existe) y
-- fn_unidad_crear / fn_unidad_actualizar vuelven a su firma de V216 / V478.
-- Depende de: V216 (TUNIDAD, fn_unidad_*), V224 (fn_unidad_estado),
-- V245 (filas de public.query), V478 (fn_unidad_actualizar), V481
-- (fn_planeador_listado_alcance).
-- ===========================================================================

SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- 1. Sin instrumento propio en TUNIDAD.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_unidad_crear(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR, BIGINT, VARCHAR[], VARCHAR[], BIGINT[], NUMERIC, BIGINT);
DROP FUNCTION IF EXISTS academico_test.fn_unidad_actualizar(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BOOLEAN, VARCHAR[], VARCHAR[], NUMERIC, BOOLEAN, BIGINT);

ALTER TABLE academico_test.TUNIDAD DROP COLUMN IF EXISTS FK_TLV_INSTRUMENTO_EVALUACION;

-- La fila existe desde V245 y ON CONFLICT no la tocaría: se le quita el
-- argumento del instrumento donde lo tenga. Sin él, no cambia nada.
UPDATE public.query
   SET query       = replace(query, E',\n    CAST(:BODY.FK_TLV_INSTRUMENTO_EVALUACION AS BIGINT)', ''),
       param_types = param_types - 'BODY.FK_TLV_INSTRUMENTO_EVALUACION',
       detail      = regexp_replace(detail, ' V488: agrega BODY\.FK_TLV_INSTRUMENTO_EVALUACION.*$', '')
 WHERE ((path_template = '/planeador/unidades'     AND http_method = 'POST')
     OR (path_template = '/planeador/unidades/:ID' AND http_method = 'PUT'))
   AND microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'eval-col')
   AND (query LIKE '%FK_TLV_INSTRUMENTO_EVALUACION%' OR param_types ? 'BODY.FK_TLV_INSTRUMENTO_EVALUACION');

-- ---------------------------------------------------------------------------
-- 2. Instrumento de la unidad.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_instrumento_derivado(
    p_pk_tunidad BIGINT
)
RETURNS TABLE (
    fk_tlv_instrumento_evaluacion BIGINT,
    instrumento_evaluacion        VARCHAR
)
LANGUAGE sql
STABLE
AS $$
    -- Las actividades sin instrumento todavía no cuentan: son las recién
    -- vinculadas, y no deben borrar el título de la unidad.
    SELECT MIN(a.FK_TLV_INSTRUMENTO_EVALUACION),
           MIN(lv.NOMBRE)::VARCHAR
      FROM academico_test.TACTIVIDAD a
      JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
     WHERE a.FK_TUNIDAD = p_pk_tunidad
       AND a.ACTIVE = TRUE
    HAVING COUNT(DISTINCT a.FK_TLV_INSTRUMENTO_EVALUACION) = 1;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_instrumento_derivado(BIGINT)
    IS 'INTERNO: instrumento de evaluación de una unidad, derivado de sus actividades activas: el único que comparten las que ya tienen instrumento. 0 filas si ninguna lo tiene o si tienen instrumentos distintos (el front usa entonces el título genérico). Lo usan fn_unidad_listar_interno y fn_unidad_buscar_por_pk_interno.';

-- ---------------------------------------------------------------------------
-- 3. Listado.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF to_regtype('academico_test.t_unidad_listado_fila') IS NULL THEN
        CREATE TYPE academico_test.t_unidad_listado_fila AS (
            pk_tunidad                    BIGINT,
            nombre                        VARCHAR,
            descripcion                   VARCHAR,
            fk_tasignatura                BIGINT,
            asignatura                    VARCHAR,
            fk_tarea                      BIGINT,
            area                          VARCHAR,
            fk_tgrado                     BIGINT,
            grado                         VARCHAR,
            fk_tfuncionario               BIGINT,
            docente                       VARCHAR,
            fk_tlv_calculo_definitiva     BIGINT,
            calculo_definitiva            VARCHAR,
            fk_referente_curricular       BIGINT,
            referente_curricular          VARCHAR,
            referente_vigente             BOOLEAN,
            total_actividades             BIGINT,
            total_objetivos               BIGINT,
            total_contenidos              BIGINT,
            fecha_inicio                  DATE,
            fecha_fin                     DATE,
            estado                        VARCHAR,
            active                        BOOLEAN,
            dia                           DATE,
            dia_anterior                  DATE,
            dia_siguiente                 DATE,
            fk_tlv_instrumento_evaluacion BIGINT,
            instrumento_evaluacion        VARCHAR,
            total_count                   BIGINT
        );
    END IF;
END $$;

COMMENT ON TYPE academico_test.t_unidad_listado_fila
    IS 'Fila de GET /planeador/unidades y su export. Una columna nueva: ALTER TYPE ... ADD ATTRIBUTE y agregarla al SELECT de fn_unidad_listar_interno.';

DROP FUNCTION IF EXISTS academico_test.fn_unidad_listar(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, BOOLEAN, VARCHAR, BOOLEAN, INT, INT, DATE, INT);

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_listar_interno(
    -- Alcance ya resuelto (fn_planeador_listado_alcance).
    p_sedes_lectura               BIGINT[],
    p_alcance_total               BOOLEAN,
    p_solo_propias                BOOLEAN,
    p_fk_tfuncionario_propio      BIGINT,
    -- Filtros.
    p_search                      VARCHAR   DEFAULT NULL,
    p_fk_tasignatura              BIGINT    DEFAULT NULL,
    p_fk_tgrado                   BIGINT    DEFAULT NULL,
    p_fk_tfuncionario             BIGINT    DEFAULT NULL,
    p_incluir_inactivos           BOOLEAN   DEFAULT FALSE,
    p_orden_por                   VARCHAR   DEFAULT 'nombre',
    p_orden_asc                   BOOLEAN   DEFAULT TRUE,
    p_limite                      INT       DEFAULT 20,
    p_offset                      INT       DEFAULT 0,
    p_dia                         DATE      DEFAULT NULL,
    p_dias_gracia                 INT       DEFAULT 2
)
RETURNS SETOF academico_test.t_unidad_listado_fila
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_key VARCHAR;
BEGIN
    v_key := LOWER(TRIM(COALESCE(p_orden_por, 'nombre')));
    IF v_key NOT IN ('nombre', 'asignatura', 'grado') THEN
        v_key := 'nombre';
    END IF;

    RETURN QUERY
    WITH universo AS (
        SELECT u.PK_TUNIDAD AS pk,
               u.NOMBRE      AS nom,
               basig.NOMBRE  AS asig_nom,
               bgr.NOMBRE    AS gr_nom
          FROM academico_test.TUNIDAD u
          JOIN academico_test.TASIGNATURA basig ON basig.PK_TASIGNATURA = u.FK_TASIGNATURA
          JOIN academico_test.TGRADO bgr        ON bgr.PK_TGRADO = u.FK_TGRADO
         WHERE (p_incluir_inactivos OR u.ACTIVE = TRUE)
           AND EXISTS (SELECT 1 FROM academico_test.TPERIODO_ACADEMICO pa_sc
                        JOIN academico_test.TSEDE s_sc
                          ON s_sc.PK_TSEDE = pa_sc.FK_TSEDE AND s_sc.ACTIVE = TRUE
                       WHERE pa_sc.PK_TPERIODO_ACADEMICO = bgr.FK_TPERIODO_ACADEMICO
                         AND (p_alcance_total
                              OR pa_sc.FK_TSEDE = ANY(p_sedes_lectura)))
           AND (p_search IS NULL OR
                (COALESCE(u.NOMBRE,'') || ' ' || COALESCE(u.DESCRIPCION,''))
                    ILIKE '%' || p_search || '%')
           AND (p_fk_tasignatura  IS NULL OR u.FK_TASIGNATURA = p_fk_tasignatura)
           AND (p_fk_tgrado       IS NULL OR u.FK_TGRADO = p_fk_tgrado)
           AND (p_fk_tfuncionario IS NULL OR u.FK_TFUNCIONARIO = p_fk_tfuncionario)
           AND (NOT p_solo_propias OR u.FK_TFUNCIONARIO = p_fk_tfuncionario_propio)
    ),
    -- La unidad no tiene fechas propias: "está" en un día si alguna de sus
    -- actividades activas lo cubre.
    del_dia AS (
        SELECT un.*
          FROM universo un
         WHERE p_dia IS NULL
            OR EXISTS (SELECT 1
                         FROM academico_test.TACTIVIDAD a_d
                        WHERE a_d.FK_TUNIDAD = un.pk
                          AND a_d.ACTIVE = TRUE
                          AND (a_d.FECHA_INICIO IS NOT NULL OR a_d.FECHA_CIERRE IS NOT NULL)
                          AND (a_d.FECHA_INICIO IS NULL OR a_d.FECHA_INICIO <= p_dia)
                          AND (a_d.FECHA_CIERRE IS NULL OR a_d.FECHA_CIERRE >= p_dia))
    ),
    nav AS (
        SELECT MAX(CASE WHEN a_n.FECHA_CIERRE IS NOT NULL AND a_n.FECHA_CIERRE < p_dia THEN a_n.FECHA_CIERRE
                        WHEN a_n.FECHA_INICIO IS NOT NULL AND a_n.FECHA_INICIO < p_dia THEN p_dia - 1
                   END) AS anterior,
               MIN(CASE WHEN a_n.FECHA_INICIO IS NOT NULL AND a_n.FECHA_INICIO > p_dia THEN a_n.FECHA_INICIO
                        WHEN a_n.FECHA_CIERRE IS NOT NULL AND a_n.FECHA_CIERRE > p_dia THEN p_dia + 1
                   END) AS siguiente
          FROM universo un
          JOIN academico_test.TACTIVIDAD a_n
                ON a_n.FK_TUNIDAD = un.pk AND a_n.ACTIVE = TRUE
         WHERE p_dia IS NOT NULL
        HAVING p_dia IS NOT NULL
    ),
    base AS (
        SELECT d.pk,
               COUNT(*) OVER() AS total
          FROM del_dia d
         ORDER BY
           CASE WHEN     p_orden_asc AND v_key = 'nombre'     THEN d.nom      END ASC  NULLS LAST,
           CASE WHEN NOT p_orden_asc AND v_key = 'nombre'     THEN d.nom      END DESC NULLS LAST,
           CASE WHEN     p_orden_asc AND v_key = 'asignatura' THEN d.asig_nom END ASC  NULLS LAST,
           CASE WHEN NOT p_orden_asc AND v_key = 'asignatura' THEN d.asig_nom END DESC NULLS LAST,
           CASE WHEN     p_orden_asc AND v_key = 'grado'      THEN d.gr_nom   END ASC  NULLS LAST,
           CASE WHEN NOT p_orden_asc AND v_key = 'grado'      THEN d.gr_nom   END DESC NULLS LAST,
           d.pk
         LIMIT CASE WHEN p_limite IS NULL THEN NULL ELSE GREATEST(p_limite, 1) END
        OFFSET GREATEST(COALESCE(p_offset, 0), 0)
    )
    SELECT u.PK_TUNIDAD,
           u.NOMBRE,
           u.DESCRIPCION,
           u.FK_TASIGNATURA,
           asig.NOMBRE,
           asig.FK_TAREA,
           ar.NOMBRE,
           u.FK_TGRADO,
           gr.NOMBRE,
           u.FK_TFUNCIONARIO,
           NULLIF(TRIM(CONCAT_WS(' ', us.PRIMER_NOMBRE, us.SEGUNDO_NOMBRE, us.PRIMER_APELLIDO, us.SEGUNDO_APELLIDO)), '')::VARCHAR,
           u.FK_TLV_CALCULO_DEFINITIVA,
           lvc.NOMBRE,
           u.FK_REFERENTE_CURRICULAR,
           rc.NOMBRE,
           (u.FK_REFERENTE_CURRICULAR IS NULL OR rc.PK_REFERENTE_CURRICULAR IS NOT NULL),
           agg.total_actividades,
           (SELECT COUNT(*) FROM academico_test.TUNIDAD_OBJETIVO o  WHERE o.FK_TUNIDAD = u.PK_TUNIDAD AND o.ACTIVE = TRUE),
           (SELECT COUNT(*) FROM academico_test.TUNIDAD_CONTENIDO c WHERE c.FK_TUNIDAD = u.PK_TUNIDAD AND c.ACTIVE = TRUE),
           agg.fecha_inicio,
           agg.fecha_fin,
           academico_test.fn_unidad_estado(u.PK_TUNIDAD, CURRENT_DATE, p_dias_gracia),
           u.ACTIVE,
           p_dia,
           n.anterior,
           n.siguiente,
           ins.fk_tlv_instrumento_evaluacion,
           ins.instrumento_evaluacion,
           COALESCE(b.total, 0)
      FROM base b
      FULL OUTER JOIN nav n ON TRUE
      LEFT JOIN academico_test.TUNIDAD u         ON u.PK_TUNIDAD = b.pk
      LEFT JOIN academico_test.TASIGNATURA asig  ON asig.PK_TASIGNATURA = u.FK_TASIGNATURA
      LEFT JOIN academico_test.TAREA ar          ON ar.PK_TAREA = asig.FK_TAREA
      LEFT JOIN academico_test.TGRADO gr         ON gr.PK_TGRADO = u.FK_TGRADO
      LEFT JOIN academico_test.TFUNCIONARIO fu   ON fu.PK_TFUNCIONARIO = u.FK_TFUNCIONARIO
      LEFT JOIN academico_test.TUSUARIO us       ON us.PK_TUSUARIO = fu.FK_TUSUARIO
      LEFT JOIN academico_test.TLISTA_VALOR lvc  ON lvc.PK_LISTA_VALOR = u.FK_TLV_CALCULO_DEFINITIVA
      -- Solo un referente vivo da nombre; referente_vigente distingue "sin
      -- referente" (FK NULL) de "con uno que ya no existe" (FK puesta).
      LEFT JOIN academico_test.TREFERENTE_CURRICULAR rc ON rc.PK_REFERENTE_CURRICULAR = u.FK_REFERENTE_CURRICULAR
                                                      AND rc.ACTIVE = TRUE
                                                      AND rc.ESTADO = 'A'
      LEFT JOIN LATERAL (
          SELECT COUNT(*)::BIGINT      AS total_actividades,
                 MIN(a.FECHA_INICIO)   AS fecha_inicio,
                 MAX(a.FECHA_CIERRE)   AS fecha_fin
            FROM academico_test.TACTIVIDAD a
           WHERE a.FK_TUNIDAD = u.PK_TUNIDAD AND a.ACTIVE = TRUE
      ) agg ON TRUE
      LEFT JOIN LATERAL academico_test.fn_unidad_instrumento_derivado(u.PK_TUNIDAD) ins ON TRUE
     ORDER BY
       CASE WHEN     p_orden_asc AND v_key = 'nombre'     THEN u.NOMBRE    END ASC  NULLS LAST,
       CASE WHEN NOT p_orden_asc AND v_key = 'nombre'     THEN u.NOMBRE    END DESC NULLS LAST,
       CASE WHEN     p_orden_asc AND v_key = 'asignatura' THEN asig.NOMBRE END ASC  NULLS LAST,
       CASE WHEN NOT p_orden_asc AND v_key = 'asignatura' THEN asig.NOMBRE END DESC NULLS LAST,
       CASE WHEN     p_orden_asc AND v_key = 'grado'      THEN gr.NOMBRE   END ASC  NULLS LAST,
       CASE WHEN NOT p_orden_asc AND v_key = 'grado'      THEN gr.NOMBRE   END DESC NULLS LAST,
       u.PK_TUNIDAD;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_listar_interno(BIGINT[], BOOLEAN, BOOLEAN, BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, BOOLEAN, VARCHAR, BOOLEAN, INT, INT, DATE, INT)
    IS 'INTERNO: página de TUNIDAD sin gate; recibe el alcance ya resuelto (fn_planeador_listado_alcance). Lo reutiliza fn_unidad_listar (GET /planeador/unidades y su export). ALCANCE: grado en una sede de lectura (o alcance total); docente puro solo SUS unidades. Nombres resueltos, referente solo si está vivo (referente_vigente), totales, fechas y estado DERIVADOS de las actividades (fn_unidad_estado con p_dias_gracia), instrumento derivado (fn_unidad_instrumento_derivado). p_dia: unidades con alguna actividad vigente ese día, con dia_anterior/dia_siguiente saltando los días vacíos. Orden por whitelist nombre|asignatura|grado. total_count via COUNT(*) OVER().';

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_listar(
    p_pk_usuario_solicitante      BIGINT,
    p_search                      VARCHAR   DEFAULT NULL,
    p_fk_tasignatura              BIGINT    DEFAULT NULL,
    p_fk_tgrado                   BIGINT    DEFAULT NULL,
    p_fk_tfuncionario             BIGINT    DEFAULT NULL,
    p_incluir_inactivos           BOOLEAN   DEFAULT FALSE,
    p_orden_por                   VARCHAR   DEFAULT 'nombre',
    p_orden_asc                   BOOLEAN   DEFAULT TRUE,
    p_limite                      INT       DEFAULT 20,
    p_offset                      INT       DEFAULT 0,
    p_dia                         DATE      DEFAULT NULL,
    p_dias_gracia                 INT       DEFAULT 2
)
RETURNS SETOF academico_test.t_unidad_listado_fila
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
    SELECT * FROM academico_test.fn_unidad_listar_interno(
        v_alc.sedes_lectura, v_alc.alcance_total, v_alc.solo_propias, v_alc.fk_tfuncionario,
        p_search, p_fk_tasignatura, p_fk_tgrado, p_fk_tfuncionario, p_incluir_inactivos,
        p_orden_por, p_orden_asc, p_limite, p_offset, p_dia, p_dias_gracia
    );
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_listar(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, BOOLEAN, VARCHAR, BOOLEAN, INT, INT, DATE, INT)
    IS 'GET /planeador/unidades y su export: gate VER sobre PLANEADOR, alcance del usuario (fn_planeador_listado_alcance) y delega en fn_unidad_listar_interno, que documenta filtros, orden y paginado por día. Devuelve t_unidad_listado_fila.';

-- ---------------------------------------------------------------------------
-- 4. Detalle.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF to_regtype('academico_test.t_unidad_detalle') IS NULL THEN
        CREATE TYPE academico_test.t_unidad_detalle AS (
            pk_tunidad                    BIGINT,
            nombre                        VARCHAR,
            descripcion                   VARCHAR,
            fk_tasignatura                BIGINT,
            asignatura                    VARCHAR,
            fk_tarea                      BIGINT,
            area                          VARCHAR,
            fk_tgrado                     BIGINT,
            grado                         VARCHAR,
            fk_tfuncionario               BIGINT,
            docente                       VARCHAR,
            fk_tlv_calculo_definitiva     BIGINT,
            calculo_definitiva            VARCHAR,
            fk_referente_curricular       BIGINT,
            referente_curricular          VARCHAR,
            referente_vigente             BOOLEAN,
            total_actividades             BIGINT,
            fecha_inicio                  DATE,
            fecha_fin                     DATE,
            objetivos                     JSONB,
            contenidos                    JSONB,
            campos_disponibles            JSONB,
            estado                        VARCHAR,
            active                        BOOLEAN,
            fk_tlv_instrumento_evaluacion BIGINT,
            instrumento_evaluacion        VARCHAR
        );
    END IF;
END $$;

COMMENT ON TYPE academico_test.t_unidad_detalle
    IS 'Fila de GET /planeador/unidades/:ID. campos_disponibles depende de quién pide: lo llena el wrapper fn_unidad_buscar_por_pk, el núcleo lo deja NULL.';

DROP FUNCTION IF EXISTS academico_test.fn_unidad_buscar_por_pk(BIGINT, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_buscar_por_pk_interno(
    p_pk_tunidad BIGINT
)
RETURNS SETOF academico_test.t_unidad_detalle
LANGUAGE sql
STABLE
AS $$
    SELECT u.PK_TUNIDAD,
           u.NOMBRE,
           u.DESCRIPCION,
           u.FK_TASIGNATURA,
           asig.NOMBRE,
           asig.FK_TAREA,
           ar.NOMBRE,
           u.FK_TGRADO,
           gr.NOMBRE,
           u.FK_TFUNCIONARIO,
           NULLIF(TRIM(CONCAT_WS(' ', us.PRIMER_NOMBRE, us.SEGUNDO_NOMBRE, us.PRIMER_APELLIDO, us.SEGUNDO_APELLIDO)), '')::VARCHAR,
           u.FK_TLV_CALCULO_DEFINITIVA,
           lvc.NOMBRE,
           u.FK_REFERENTE_CURRICULAR,
           rc.NOMBRE,
           (u.FK_REFERENTE_CURRICULAR IS NULL OR rc.PK_REFERENTE_CURRICULAR IS NOT NULL),
           agg.total_actividades,
           agg.fecha_inicio,
           agg.fecha_fin,
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object('pk', o.PK_TUNIDAD_OBJETIVO, 'orden', o.ORDEN, 'descripcion', o.DESCRIPCION)
                                ORDER BY o.ORDEN)
                 FROM academico_test.TUNIDAD_OBJETIVO o
                WHERE o.FK_TUNIDAD = u.PK_TUNIDAD AND o.ACTIVE = TRUE
           ), '[]'::jsonb),
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object('pk', c.PK_TUNIDAD_CONTENIDO, 'orden', c.ORDEN, 'descripcion', c.DESCRIPCION)
                                ORDER BY c.ORDEN)
                 FROM academico_test.TUNIDAD_CONTENIDO c
                WHERE c.FK_TUNIDAD = u.PK_TUNIDAD AND c.ACTIVE = TRUE
           ), '[]'::jsonb),
           NULL::JSONB,
           academico_test.fn_unidad_estado(u.PK_TUNIDAD, CURRENT_DATE),
           u.ACTIVE,
           ins.fk_tlv_instrumento_evaluacion,
           ins.instrumento_evaluacion
      FROM academico_test.TUNIDAD u
      JOIN academico_test.TASIGNATURA asig       ON asig.PK_TASIGNATURA = u.FK_TASIGNATURA
      LEFT JOIN academico_test.TAREA ar          ON ar.PK_TAREA = asig.FK_TAREA
      JOIN academico_test.TGRADO gr              ON gr.PK_TGRADO = u.FK_TGRADO
      LEFT JOIN academico_test.TFUNCIONARIO fu   ON fu.PK_TFUNCIONARIO = u.FK_TFUNCIONARIO
      LEFT JOIN academico_test.TUSUARIO us       ON us.PK_TUSUARIO = fu.FK_TUSUARIO
      LEFT JOIN academico_test.TLISTA_VALOR lvc  ON lvc.PK_LISTA_VALOR = u.FK_TLV_CALCULO_DEFINITIVA
      LEFT JOIN academico_test.TREFERENTE_CURRICULAR rc ON rc.PK_REFERENTE_CURRICULAR = u.FK_REFERENTE_CURRICULAR
                                                      AND rc.ACTIVE = TRUE
                                                      AND rc.ESTADO = 'A'
      LEFT JOIN LATERAL (
          SELECT COUNT(*)::BIGINT    AS total_actividades,
                 MIN(a.FECHA_INICIO) AS fecha_inicio,
                 MAX(a.FECHA_CIERRE) AS fecha_fin
            FROM academico_test.TACTIVIDAD a
           WHERE a.FK_TUNIDAD = u.PK_TUNIDAD AND a.ACTIVE = TRUE
      ) agg ON TRUE
      LEFT JOIN LATERAL academico_test.fn_unidad_instrumento_derivado(u.PK_TUNIDAD) ins ON TRUE
     WHERE u.PK_TUNIDAD = p_pk_tunidad;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_buscar_por_pk_interno(BIGINT)
    IS 'INTERNO: detalle de una TUNIDAD sin gate, incluidas las inactivas (0 o 1 fila): nombres resueltos, total de actividades activas, inicio/fin derivados, objetivos y contenidos JSONB, estado derivado e instrumento derivado (fn_unidad_instrumento_derivado). campos_disponibles va NULL: depende de quién pide y lo pone el wrapper. Lo reutiliza fn_unidad_buscar_por_pk.';

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_buscar_por_pk(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tunidad               BIGINT
)
RETURNS SETOF academico_test.t_unidad_detalle
LANGUAGE plpgsql
AS $$
DECLARE
    v_fila academico_test.t_unidad_detalle;
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', NULL, NULL, p_pk_tunidad
    );

    FOR v_fila IN SELECT * FROM academico_test.fn_unidad_buscar_por_pk_interno(p_pk_tunidad) LOOP
        v_fila.campos_disponibles := academico_test.fn_unidad_campos_disponibles(
            p_pk_usuario_solicitante, p_pk_tunidad);
        RETURN NEXT v_fila;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_buscar_por_pk(BIGINT, BIGINT)
    IS 'GET /planeador/unidades/:ID: gate VER con alcance sobre la unidad (fn_planeador_assert_alcance), delega en fn_unidad_buscar_por_pk_interno y añade campos_disponibles del usuario (fn_unidad_campos_disponibles). Devuelve t_unidad_detalle, 0 o 1 fila.';
