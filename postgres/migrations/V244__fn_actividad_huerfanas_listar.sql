-- ===========================================================================
-- V244 - Planeador: fn_actividad_huerfanas_listar (actividades sin unidad).
--
-- El DROP de la firma de 4 parametros de fn_unidad_actividad_vincular se queda
-- para servidores que aun la tengan; la vigente vive en V492.3.
-- ===========================================================================


SET search_path TO academico_test, public;

DROP FUNCTION IF EXISTS academico_test.fn_unidad_actividad_vincular(BIGINT, BIGINT, BIGINT, NUMERIC);

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_huerfanas_listar(
    p_pk_usuario_solicitante   BIGINT,
    p_search                   VARCHAR DEFAULT NULL,
    p_fk_tasignatura           BIGINT  DEFAULT NULL,
    p_fk_tgrupo                BIGINT  DEFAULT NULL,
    p_fecha_desde              DATE    DEFAULT NULL,
    p_fecha_hasta              DATE    DEFAULT NULL,
    p_pagina                   INT     DEFAULT 1,
    p_tamano_pagina            INT     DEFAULT 20
)
RETURNS TABLE (
    pk_tactividad           BIGINT,
    titulo                  VARCHAR,
    fk_tlv_tipo_actividad   BIGINT,
    tipo_actividad          VARCHAR,
    fk_tasignatura          BIGINT,
    asignatura              VARCHAR,
    fk_tgrupo               BIGINT,
    grupo                   VARCHAR,
    fk_tgrado               BIGINT,
    grado                   VARCHAR,
    fecha_inicio            DATE,
    fecha_cierre            DATE,
    total_count             BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_sedes_lectura BIGINT[];
    v_alcance_total BOOLEAN;
    v_limite INT;
    v_offset INT;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    -- Alcance de LECTURA (V277). El criterio no se elige aqui: ya lo define el
    -- sistema de rol/menu, via fn_usuario_sedes_lectura -- nivel 0/1 todas las
    -- sedes, nivel 2 las de sus establecimientos, nivel 3 las suyas, nivel 4
    -- ninguna. Se resuelve una sola vez por llamada.
    -- Nivel 0 (super admin) y 1 (territoriales) no se acotan por alcance
    -- territorial: ven todas las sedes. Lo que NO se salta nadie, ni ellos,
    -- es el borrado logico: el ACTIVE de la sede va en el JOIN de abajo, no
    -- aqui, para que una sede desactivada quede oculta para todo el mundo.
    v_alcance_total := COALESCE(
        academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario_solicitante), 99) <= 1;
    v_sedes_lectura := ARRAY(
        SELECT sl.sede_id
          FROM academico_test.fn_usuario_sedes_lectura(p_pk_usuario_solicitante) sl);

    v_limite := GREATEST(COALESCE(p_tamano_pagina, 20), 1);
    v_offset := (GREATEST(COALESCE(p_pagina, 1), 1) - 1) * v_limite;

    RETURN QUERY
    WITH base AS (
        SELECT a.PK_TACTIVIDAD AS pk,
               COUNT(*) OVER() AS total
          FROM academico_test.TACTIVIDAD a
         WHERE a.ACTIVE = TRUE
           AND a.FK_TUNIDAD IS NULL
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
                            AND (v_alcance_total
                                 OR pa_sc.FK_TSEDE = ANY(v_sedes_lectura)))
              -- Sin grupo no hay sede: solo la ve quien la creo. CREATED_BY es
              -- VARCHAR (auditoria de texto libre), de ahi el cast.
              OR (a.FK_TGRUPO IS NULL AND (v_alcance_total
                      OR a.CREATED_BY = p_pk_usuario_solicitante::VARCHAR))
               )
           AND (p_fk_tasignatura IS NULL OR a.FK_TASIGNATURA = p_fk_tasignatura)
           AND (p_fk_tgrupo      IS NULL OR a.FK_TGRUPO = p_fk_tgrupo)
           AND (p_fecha_desde IS NULL OR COALESCE(a.FECHA_CIERRE, a.FECHA_INICIO) >= p_fecha_desde)
           AND (p_fecha_hasta IS NULL OR COALESCE(a.FECHA_INICIO, a.FECHA_CIERRE) <= p_fecha_hasta)
           -- Misma expresion que idx_tactividad_busqueda_trgm (V224).
           AND (p_search IS NULL OR
                (COALESCE(a.TITULO,'') || ' ' || COALESCE(a.DESCRIPCION,''))
                    ILIKE '%' || p_search || '%')
         ORDER BY a.FECHA_INICIO NULLS LAST, a.PK_TACTIVIDAD
         LIMIT v_limite
        OFFSET v_offset
    )
    SELECT a.PK_TACTIVIDAD,
           a.TITULO,
           a.FK_TLV_TIPO_ACTIVIDAD,
           lvt.NOMBRE,
           a.FK_TASIGNATURA,
           asig.NOMBRE,
           a.FK_TGRUPO,
           g.NOMBRE,
           g.FK_TGRADO,
           gr.NOMBRE,
           a.FECHA_INICIO,
           a.FECHA_CIERRE,
           b.total
      FROM base b
      JOIN academico_test.TACTIVIDAD a          ON a.PK_TACTIVIDAD = b.pk
      JOIN academico_test.TASIGNATURA asig      ON asig.PK_TASIGNATURA = a.FK_TASIGNATURA
      LEFT JOIN academico_test.TGRUPO g         ON g.PK_TGRUPO = a.FK_TGRUPO
      LEFT JOIN academico_test.TGRADO gr        ON gr.PK_TGRADO = g.FK_TGRADO
      LEFT JOIN academico_test.TLISTA_VALOR lvt ON lvt.PK_LISTA_VALOR = a.FK_TLV_TIPO_ACTIVIDAD
     ORDER BY a.FECHA_INICIO NULLS LAST, a.PK_TACTIVIDAD;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_huerfanas_listar(BIGINT, VARCHAR, BIGINT, BIGINT, DATE, DATE, INT, INT)
    IS 'Actividades sin unidad (TACTIVIDAD.FK_TUNIDAD IS NULL, ACTIVE) para la pantalla de vinculacion posterior: filtra por asignatura, grupo y ventana de fechas (mismos criterios que fn_actividad_listar, V224), p_search hace ILIKE sobre TITULO+DESCRIPCION con la misma expresion de idx_tactividad_busqueda_trgm (V224, no se crea indice nuevo). No proyecta PONDERACION: una huerfana siempre la tiene en NULL (solo fn_unidad_actividad_vincular la fija al asignar unidad; fn_unidad_actividad_desvincular la limpia junto con FK_TUNIDAD), documentado en vez de inventar un valor. Para vincular una fila del resultado, usar fn_unidad_actividad_vincular (V223/V244). Paginado con p_pagina/p_tamano_pagina, total_count via COUNT(*) OVER() sobre el mismo patron CTE-base de fn_actividad_listar. Gate VER sobre PLANEADOR. V244.';
