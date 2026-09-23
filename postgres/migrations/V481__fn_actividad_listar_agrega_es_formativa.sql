-- ===========================================================================
-- V481 — fn_actividad_listar agrega ES_FORMATIVA.
--
-- BUG REPORTADO EN VIVO: la card de una actividad en el rail del Planeador
-- (tablero + "Ver detalles" de una tarjeta, ambos resueltos por esta
-- funcion via fn_actividad_listar_docente) mostraba el boton "Aprobar"
-- (calificacion en bloque) para una actividad FORMATIVA (tipo "Participacion
-- en clase", grado Pre-Jardin, ES_EVALUATIVA='N') -- ese boton no aplica a
-- Formativo (se observa, no se califica en bloque), y el DETALLE de la misma
-- actividad (otra fuente, `fn_actividad_buscar_por_pk`) sí lo ocultaba bien.
--
-- POR QUE: el front decide con `actividad.esFormativa` (`ActividadCard`,
-- `esActividadFormativa` en `actividad-formativa.ts`), que sale de la
-- columna `es_formativa` de la fila -- pero esta funcion NUNCA la devolvio:
-- confirmado contra una respuesta real de GET /planeador/actividades
-- (idéntica a la que arma GET /planeador/actividades/mias vía
-- fn_actividad_listar_docente) -- la columna no está en el JSON. El front
-- trata "ausente" como "no formativa" (mismo default que el backend usa
-- cuando no hay de donde derivarlo), así que el boton se mostraba siempre.
-- `fn_planilla_columnas_listar` (V454, misma migracion base) SÍ la trae
-- desde V441 -- es otra funcion, para la pantalla de Planilla, no esta.
--
-- FIX: se agrega ES_FORMATIVA (fn_actividad_es_formativa, V475/V476 -- ya
-- usada por fn_planilla_columnas_listar) al RETURNS TABLE de
-- fn_actividad_listar. Cambiar el RETURNS TABLE de una funcion existente no
-- lo permite CREATE OR REPLACE -- se necesita DROP FUNCTION IF EXISTS
-- primero, mismo patron ya usado en este archivo (V479/V480) para
-- fn_unidad_actividades_listar/fn_unidad_buscar_por_pk.
--
-- fn_actividad_listar_docente (V224, `SELECT * FROM fn_actividad_listar(...)`)
-- no necesita tocarse: al ser `SELECT *` hereda la columna nueva sola.
--
-- Depende de: V224 (fn_actividad_listar), V475/V476 (fn_actividad_es_formativa).
-- ===========================================================================

SET search_path TO academico_test, public;

DROP FUNCTION IF EXISTS academico_test.fn_actividad_listar(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, DATE, DATE, VARCHAR[], INT, BOOLEAN, VARCHAR, BOOLEAN, INT, INT, BIGINT, DATE);

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
RETURNS TABLE (
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
    -- V481: para que el front pueda ocultar acciones que no aplican a una
    -- actividad Formativa (ej. "Aprobar" / calificación en bloque, ver
    -- `esActividadFormativa` en actividad-formativa.ts) sin tener que abrir
    -- el detalle completo primero.
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
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_sedes_lectura BIGINT[];
    v_alcance_total BOOLEAN;
    v_solo_propias  BOOLEAN;
    v_fk_tfuncionario BIGINT;
    v_hoy  DATE := CURRENT_DATE;
    v_key  VARCHAR;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    v_solo_propias    := academico_test.fn_usuario_es_docente_puro(p_pk_usuario_solicitante);
    v_fk_tfuncionario := academico_test.fn_funcionario_actual(p_pk_usuario_solicitante);

    v_alcance_total := COALESCE(
        academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario_solicitante), 99) <= 1;
    v_sedes_lectura := ARRAY(
        SELECT sl.sede_id
          FROM academico_test.fn_usuario_sedes_lectura(p_pk_usuario_solicitante) sl);

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
                            AND (v_alcance_total
                                 OR pa_sc.FK_TSEDE = ANY(v_sedes_lectura)))
              OR EXISTS (SELECT 1
                           FROM academico_test.TUNIDAD u_sc
                           JOIN academico_test.TGRADO gr_sc
                             ON gr_sc.PK_TGRADO = u_sc.FK_TGRADO
                           JOIN academico_test.TPERIODO_ACADEMICO pa_sc
                             ON pa_sc.PK_TPERIODO_ACADEMICO = gr_sc.FK_TPERIODO_ACADEMICO
                           JOIN academico_test.TSEDE s_sc
                             ON s_sc.PK_TSEDE = pa_sc.FK_TSEDE AND s_sc.ACTIVE = TRUE
                          WHERE u_sc.PK_TUNIDAD = a.FK_TUNIDAD
                            AND (v_alcance_total
                                 OR pa_sc.FK_TSEDE = ANY(v_sedes_lectura)))
              OR (a.FK_TGRUPO IS NULL AND a.FK_TUNIDAD IS NULL
                  AND (v_alcance_total
                      OR a.CREATED_BY = p_pk_usuario_solicitante::VARCHAR))
               )
           AND (p_fk_tasignatura        IS NULL OR a.FK_TASIGNATURA = p_fk_tasignatura)
           AND (p_fk_tgrupo             IS NULL OR a.FK_TGRUPO = p_fk_tgrupo)
           AND (p_fk_tunidad            IS NULL OR a.FK_TUNIDAD = p_fk_tunidad)
           AND (p_fk_tfuncionario       IS NULL OR EXISTS (
                    SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA da
                     WHERE da.FK_TGRUPO      = a.FK_TGRUPO
                       AND da.FK_TASIGNATURA = a.FK_TASIGNATURA
                       AND da.FK_TFUNCIONARIO = p_fk_tfuncionario
                       AND da.ACTIVE = TRUE))
           AND (NOT v_solo_propias
                OR EXISTS (SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA da
                            WHERE da.FK_TGRUPO       = a.FK_TGRUPO
                              AND da.FK_TASIGNATURA  = a.FK_TASIGNATURA
                              AND da.FK_TFUNCIONARIO = v_fk_tfuncionario
                              AND da.ACTIVE = TRUE)
                OR (a.FK_TGRUPO IS NULL AND a.FK_TUNIDAD IS NULL
                    AND a.CREATED_BY = p_pk_usuario_solicitante::VARCHAR))
           AND (p_fk_tlv_tipo_actividad IS NULL OR a.FK_TLV_TIPO_ACTIVIDAD = p_fk_tlv_tipo_actividad)
           AND (p_fk_tlv_instrumento    IS NULL OR a.FK_TLV_INSTRUMENTO_EVALUACION = p_fk_tlv_instrumento)
           AND (p_fecha_desde IS NULL OR COALESCE(a.FECHA_CIERRE, a.FECHA_INICIO) >= p_fecha_desde)
           AND (p_fecha_hasta IS NULL OR COALESCE(a.FECHA_INICIO, a.FECHA_CIERRE) <= p_fecha_hasta)
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
           CASE WHEN prog.asignados > 0
                THEN ROUND(prog.evaluados * 100.0 / prog.asignados, 2)
                ELSE 0 END,
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
      -- Un solo LATERAL: asignados y evaluados en la misma pasada. Evaluado =
      -- con nota, o con OBSERVACION y CALIFICABLE='N' (formativa/preescolar):
      -- la misma regla que fn_actividad_finalizacion_refrescar.
      LEFT JOIN LATERAL (
          SELECT COUNT(*)::BIGINT AS asignados,
                 COUNT(*) FILTER (
                     WHERE ( COALESCE(n.DEFINITIVA, n.CALIFICACION) IS NOT NULL
                        OR (n.CALIFICABLE = 'N' AND NULLIF(TRIM(n.OBSERVACION), '') IS NOT NULL) )
                 )::BIGINT AS evaluados
            FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
            LEFT JOIN academico_test.TACTIVIDAD_NOTA n
                   ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                  AND n.ACTIVE = TRUE
           WHERE ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
             AND ae.ACTIVE = TRUE
      ) prog ON TRUE
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

COMMENT ON FUNCTION academico_test.fn_actividad_listar(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, DATE, DATE, VARCHAR[], INT, BOOLEAN, VARCHAR, BOOLEAN, INT, INT, BIGINT, DATE)
    IS 'estudiantes_evaluados cuenta como evaluado al que tiene nota O al que tiene OBSERVACION con CALIFICABLE = N -- la via de las actividades formativas/preescolar (V243) --, con la misma regla que fn_actividad_finalizacion_refrescar; antes solo contaba la nota y una formativa con todos sus estudiantes observados mostraba 0 evaluados. ALCANCE: la sede acota QUE se ve (fn_usuario_sedes_lectura, V29) y, ademas, a un docente puro (fn_usuario_es_docente_puro, V29) se le acota a las actividades que DICTA (cruce por TDOCENTE_ASIGNATURA, mismo criterio que fn_actividad_listar_docente) mas las huerfanas que creo el. Sin ese segundo recorte veia las de toda su sede: el endpoint general GET /planeador/actividades pasa NULL en p_fk_tfuncionario, asi que el filtro por parametro nunca se activaba por esa ruta. Rector, secretaria y coordinador conservan intacto el alcance territorial. Pagina de actividades del Planeador (gate VER). p_dia es el PAGINADO POR DIA ACTIVO (la barra "Hoy | MARTES 16 | < >" del tablero): deja solo las actividades VIGENTES ese dia -- las que lo CUBREN con su ventana [FECHA_INICIO, FECHA_CIERRE], no las que empiezan o cierran exactamente ese dia, para que una actividad de tres dias aparezca en los tres --, con la misma tolerancia a un extremo faltante que fn_actividad_estado; una actividad sin ninguna fecha no esta en ningun dia y no aparece en esta vista. NULL = sin paginado por dia. Devuelve ademas dia / dia_anterior / dia_siguiente para las flechas: son el dia ocupado mas cercano a cada lado bajo los MISMOS filtros, SALTANDO los dias vacios (sin eso las flechas avanzarian de a un dia sobre semanas sin nada), y NULL cuando no hay mas dias por ese lado. Se calculan sobre el universo SIN el filtro por dia -- si mirasen la pagina no verian nada fuera del dia actual --, por eso el filtro vive en un CTE (universo) del que salen tanto la pagina como la navegacion, sin escribirlo dos veces. DIA VACIO: cuando se pide p_dia y ese dia no tiene ninguna actividad, se devuelve UNA fila con las columnas de la actividad en NULL, total_count = 0 y las flechas informadas -- sin ella el cliente se quedaria sin con que SALIR de un dia vacio. Se reconoce por total_count = 0 (o pk_tactividad NULL). Sin p_dia el comportamiento no cambia en nada: una pagina vacia sigue siendo 0 filas. Filtros indexados: asignatura, grupo, unidad, tipo, instrumento y ventana de fechas. p_search es el buscador unico "nombre, nivel educativo o instrumento": matchea (a) TITULO+DESCRIPCION con la expresion identica a la de idx_tactividad_busqueda_trgm, (b) el NOMBRE del nivel de ensenanza de la actividad (via FK_TUNIDAD -> TUNIDAD.FK_TGRADO -> TGRADO.FK_TNIVEL_ENSENANZA -> TNIVEL_ENSENANZA; solo aplica si la actividad tiene unidad) y (c) el NOMBRE del instrumento (TLISTA_VALOR de FK_TLV_INSTRUMENTO_EVALUACION). HONESTIDAD DE RENDIMIENTO: solo (a) puede entrar por el indice trigram; (b) y (c) son un post-filtro por EXISTS NO indexado sobre catalogos pequeños que, al ir en OR, impide el Bitmap Index Scan puro del trigram cuando p_search viene informado -- se evalua dentro del mismo CTE base ya acotado por los demas filtros y por LIMIT/OFFSET, nunca sobre un seq scan del universo sin filtrar. p_estados filtra por el estado DERIVADO (fn_actividad_estado) con p_dias_gracia (default 2). p_fk_tfuncionario (V250, al final de la firma para no romper la llamada posicional ya registrada de V246) filtra por el docente que DICTA la actividad -- NO el autor de la unidad (TUNIDAD.FK_TFUNCIONARIO puede ser otro docente o un coordinador): se resuelve via TDOCENTE_ASIGNATURA (V46, mismo vinculo que fn_docente_grupos_listar/V242) cruzando por (FK_TGRUPO, FK_TASIGNATURA) de la actividad, EXISTS -- actividades sin FK_TGRUPO (p.ej. un "Criterio") quedan fuera cuando se usa este filtro. Orden (whitelist): fecha_inicio|fecha_cierre|fecha_creacion|titulo|ponderacion, cualquier otro valor cae a fecha_inicio. Devuelve nombres resueltos (asignatura, area, unidad, grupo, tipo, instrumento), el GRADO de la actividad -- del grupo, o de su unidad cuando no tiene grupo -- con fk_tgrado / grado / grado_codigo y la etiqueta compuesta grado_grupo (fn_grado_grupo_etiqueta: CODIGO del grado + grupo, ''6''+''01'' -> ''601''; si el nombre del grupo ya trae el codigo del grado se devuelve tal cual, ''803M'', para no producir ''8803M''), el estado derivado y el progreso de evaluacion (asignados/evaluados/%). V481: agrega ES_FORMATIVA (fn_actividad_es_formativa, V475/V476) -- antes esta funcion no la devolvia (a diferencia de fn_planilla_columnas_listar, que sí la trae desde V441), asi que el front (ActividadCard) mostraba "Aprobar" (bulk) para actividades Formativas: el campo ausente se trataba como "no formativa". Optimizacion: el CTE base pagina tocando solo TACTIVIDAD y los joins + el LATERAL de progreso corren unicamente contra las filas de la pagina. total_count via COUNT(*) OVER(). V224/V250, editada en V481.';
