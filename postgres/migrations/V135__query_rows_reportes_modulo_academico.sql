-- =============================================================================
-- V135 — endpoints de reporte para areas, escalas, plan-estudio, grados y
--        asignaciones.
--
-- Mismo patron que V67 (funcionarios/establecimientos/sedes) y V124
-- (periodos academicos/evaluacion): una fila de public.query por dominio
-- reportable, llamando a la MISMA funcion del listado con las paginas en
-- NULL::INTEGER para que el reporte salga completo (el helper
-- `LIMIT NULLIF($n, 0)` de V130 ya esta en cada funcion).
--
-- Agregar un reporte = una fila query (migracion) + una entrada en
-- `reporting.reports.*` del reporting-service (ver V67 comentario de
-- cabecera). Sin ambas cosas el reporte responde 404: la fila sola no
-- alcanza porque el reporting-service descubre las rutas que conoce por
-- su `application.yml`, no por introspection del catalogo.
--
-- Idempotente: los INSERT usan los mismos UUIDs sembrados a mano en el
-- servidor de test durante la primera iteracion de los reportes del
-- modulo academico (`q-mt9...`). Si el UUID ya existe, noop — la fila
-- queda exactamente como esta hoy en ese entorno. Esto permite commitear
-- la migracion sin pisar trabajo previo ya en produccion, y permite que
-- un entorno desde cero termine en el mismo estado sin intervencion
-- manual.
--
-- Funciones nuevas (las 4 que faltaban):
--   - fn_area_subject_reporte_listar       (V135, areas + asignaturas por periodo)
--   - fn_grado_grupo_reporte_listar        (V135, grado + grupo + director + jornada + plan)
--   - fn_asignacion_reporte_listar         (V135, docente + asignatura + grado + grupo)
-- Reutilizadas:
--   - fn_escala_listar                     (V42/V97, sin cambios)
--   - fn_plan_reporte_listar               (V136, en origin/feature/CU-86e2427dp;
--                                            fusionar manualmente al rebase)
--
-- Todas replican el patron del modulo: `LIMIT NULLIF(p_page_size, 0)` para
-- que el reporte salga completo, `fn_periodo_usuario_puede_ver(...)` como
-- gate de autorizacion, y los filtros por FK_* como arreglos con la
-- convencion `(p_fk_xxx IS NULL OR CARDINALITY(p_fk_xxx) = 0 OR ... = ANY(...))`
-- para que mandar `null` o `[]` signifique "no filtrar".
--
-- Autorizacion: misma regla que V67/V124 — "quien ve el listado puede
-- exportarlo". Los role_query se copian de las queries de listado
-- correspondientes en V37/V38/V40/V42/V43/V44/V46; lo que V67 y V124 ya
-- hacen, repetido aca para los5 nuevos dominios.
--
-- `export-selected-*` (patron V69: filtro `ids`) SI esta implementado en
-- esta migracion: cada query agrega `BODY.FILTERS.IDS BIGINT[]` a su
-- `param_types` y un `WHERE ... = ANY(...)` por fuera de la llamada a la
-- funcion. El recorte va DESPUES de que la funcion aplico su propio gate
-- de autorizacion (`fn_periodo_usuario_puede_ver`), asi que mandar un id
-- de una fila que el usuario no puede ver no la revela — el gate ya
-- filtro antes, el ANY solo recorta dentro de lo visible.
--
-- El costo es real y conviene tenerlo presente: la funcion materializa
-- todas las filas que pasan los demas filtros y recorta por id despues.
-- Para "exportar 1 seleccionado" eso significa calcular el listado
-- completo y descartar el resto. Es aceptable porque el conjunto ya esta
-- acotado por los permisos del usuario y porque exportar no es una
-- operacion interactiva; si algun dia pesa, el arreglo es el parametro
-- en la funcion, con el DROP + CREATE que implica (mismo analisis que
-- hizo V69).
-- =============================================================================

SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- fn_area_subject_reporte_listar — areas del periodo, con sus asignaturas
-- y enfasis (LEFT JOIN porque un area sin asignaturas o una asignatura sin
-- enfasis siguen siendo filas validas para el reporte).
--
-- Diferencia con fn_periodo_areas_asignaturas_listar (V40): esa devuelve
-- `asignaturas` como un jsonb anidado; la pantalla del sheet lo consume
-- asi. El reporte quiere una FILA por area-asignatura (no por area), y
-- ademas expone `especialidad_id`/`especialidad_name` resolviendo el
-- `FK_TENFASIS` — la pantalla no necesita la FK, ya esta editando
-- dentro de un area puntual.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_area_subject_reporte_listar(
    p_fk_periodo        BIGINT,
    p_fk_area           BIGINT[] DEFAULT NULL,
    p_fk_asignatura     BIGINT[] DEFAULT NULL,
    p_fk_especialidad   BIGINT[] DEFAULT NULL,
    p_incluir_inactivos BOOLEAN  DEFAULT FALSE,
    p_pk_usuario        BIGINT   DEFAULT NULL,
    p_page_index        INT      DEFAULT 0,
    p_page_size         INT      DEFAULT 10
)
RETURNS TABLE (
    area_id BIGINT, area_general_name VARCHAR, area_nombre_interno VARCHAR,
    area_abreviacion VARCHAR, asignatura_id BIGINT, asignatura VARCHAR,
    asignatura_abreviacion VARCHAR, especialidad_id BIGINT,
    especialidad_name VARCHAR, orden_reportes NUMERIC, color VARCHAR,
    total_count BIGINT
)
LANGUAGE sql STABLE AS $$
    SELECT a.PK_TAREA, ta.NOMBRE, a.NOMBRE, a.CODIGO,
           s.PK_TASIGNATURA, s.NOMBRE, s.CODIGO,
           en.PK_TENFASIS, en.NOMBRE,
           s.ORDEN_REPORTE, s.COLOR,
           count(*) OVER()::BIGINT
      FROM academico_test.TAREA a
      JOIN academico_test.TAREA_ASIGNATURA ta ON ta.PK_TAREA_ASIGNATURA = a.FK_TAREA_ASIGNATURA
 LEFT JOIN academico_test.TASIGNATURA s        ON s.FK_TAREA = a.PK_TAREA
                                               AND (p_incluir_inactivos OR s.ACTIVE = TRUE)
 LEFT JOIN academico_test.TENFASIS en          ON en.PK_TENFASIS = s.FK_TENFASIS
     WHERE a.FK_TPERIODO_ACADEMICO = p_fk_periodo
       AND (p_incluir_inactivos OR a.ACTIVE = TRUE)
       AND academico_test.fn_periodo_usuario_puede_ver(p_pk_usuario, p_fk_periodo)
       AND (p_fk_area         IS NULL OR CARDINALITY(p_fk_area)         = 0 OR a.PK_TAREA      = ANY(p_fk_area))
       AND (p_fk_asignatura   IS NULL OR CARDINALITY(p_fk_asignatura)   = 0 OR s.PK_TASIGNATURA = ANY(p_fk_asignatura))
       AND (p_fk_especialidad IS NULL OR CARDINALITY(p_fk_especialidad) = 0 OR en.PK_TENFASIS    = ANY(p_fk_especialidad))
     ORDER BY a.ORDEN_REPORTE, a.NOMBRE, s.ORDEN_REPORTE, s.NOMBRE
     LIMIT NULLIF(p_page_size, 0)
    OFFSET COALESCE(p_page_index, 0) * COALESCE(NULLIF(p_page_size, 0), 0);
$$;

-- ---------------------------------------------------------------------------
-- fn_grado_grupo_reporte_listar — una fila por (grado, grupo). Si un grado
-- no tiene grupos cargados, sale igual con `grupo_*` y `director_*` en NULL
-- (LEFT JOIN). El plan de estudio se resuelve via LATERAL para tomar el
-- primer PLAN activo del grado — suficiente para el reporte, sin meter un
-- GROUP BY o un array que complique la salida.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_grado_grupo_reporte_listar(
    p_fk_periodo BIGINT,
    p_fk_grado   BIGINT[] DEFAULT NULL,
    p_pk_usuario BIGINT   DEFAULT NULL,
    p_page_index INT      DEFAULT 0,
    p_page_size  INT      DEFAULT 10
)
RETURNS TABLE (
    grado_id BIGINT, grado_name VARCHAR, grado_codigo VARCHAR,
    teaching_level_id BIGINT, teaching_level_name VARCHAR,
    grupo_id BIGINT, grupo_name VARCHAR,
    jornada_id BIGINT, jornada_name VARCHAR,
    director_id BIGINT, director_name TEXT,
    plan_estudio_name VARCHAR, total_count BIGINT
)
LANGUAGE sql STABLE AS $$
    SELECT g.PK_TGRADO, g.NOMBRE, g.CODIGO,
           g.FK_TNIVEL_ENSENANZA, ne.NOMBRE,
           gr.PK_TGRUPO, gr.NOMBRE,
           jor.PK_LISTA_VALOR, jor.NOMBRE,
           df.PK_TFUNCIONARIO,
           NULLIF(TRIM(regexp_replace(
               concat_ws(' ', du.PRIMER_NOMBRE, du.SEGUNDO_NOMBRE, du.PRIMER_APELLIDO, du.SEGUNDO_APELLIDO),
               '\s+', ' ', 'g')), ''),
           plan.NOMBRE,
           count(*) OVER()::BIGINT
      FROM academico_test.TGRADO g
      JOIN academico_test.TNIVEL_ENSENANZA ne ON ne.PK_NIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
 LEFT JOIN academico_test.TGRUPO gr            ON gr.FK_TGRADO = g.PK_TGRADO AND gr.ACTIVE = TRUE
 LEFT JOIN academico_test.TLISTA_VALOR jor     ON jor.PK_LISTA_VALOR = gr.FK_TLV_JORNADA
 LEFT JOIN academico_test.TFUNCIONARIO df      ON df.PK_TFUNCIONARIO = gr.FK_TFUNCIONARIO
 LEFT JOIN academico_test.TUSUARIO du          ON du.PK_TUSUARIO = df.FK_TUSUARIO
 LEFT JOIN LATERAL (
       SELECT p.NOMBRE
         FROM academico_test.TPLAN p
        WHERE p.FK_TGRADO = g.PK_TGRADO AND p.ACTIVE = TRUE
        ORDER BY p.PK_TPLAN
        LIMIT 1
 ) plan ON TRUE
     WHERE g.FK_TPERIODO_ACADEMICO = p_fk_periodo AND g.ACTIVE = TRUE
       AND academico_test.fn_periodo_usuario_puede_ver(p_pk_usuario, p_fk_periodo)
       AND (p_fk_grado IS NULL OR CARDINALITY(p_fk_grado) = 0 OR g.PK_TGRADO = ANY(p_fk_grado))
     ORDER BY g.NOMBRE, gr.NOMBRE
     LIMIT NULLIF(p_page_size, 0)
    OFFSET COALESCE(p_page_index, 0) * COALESCE(NULLIF(p_page_size, 0), 0);
$$;

-- ---------------------------------------------------------------------------
-- fn_asignacion_reporte_listar — asignacion consolidada docente+grado+grupo+
-- asignatura+jornada. JOIN a TDOCENTE_ASIGNATURA (tabla pivote) que es la
-- fuente: el join con TSEDE_USUARIO filtra solo docentes con sede activa
-- (LEFT porque un docente puede no tener sede_usuario activa y aun asi
-- tener asignaciones historicas que el reporte debe reflejar).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_asignacion_reporte_listar(
    p_fk_periodo    BIGINT,
    p_fk_funcionario BIGINT[] DEFAULT NULL,
    p_fk_grado      BIGINT[] DEFAULT NULL,
    p_fk_asignatura BIGINT[] DEFAULT NULL,
    p_fk_jornada    BIGINT[] DEFAULT NULL,
    p_estado        TEXT     DEFAULT NULL,
    p_pk_usuario    BIGINT   DEFAULT NULL,
    p_page_index    INT      DEFAULT 0,
    p_page_size     INT      DEFAULT 10
)
RETURNS TABLE (
    docente_id BIGINT, document_number VARCHAR, docente_nombre TEXT,
    estado TEXT,
    asignatura_id BIGINT, asignatura VARCHAR,
    grado_id BIGINT, grado_name VARCHAR,
    grupo_id BIGINT, grupo_name VARCHAR,
    jornada_id BIGINT, jornada_name VARCHAR,
    total_count BIGINT
)
LANGUAGE sql STABLE AS $$
    SELECT f.PK_TFUNCIONARIO, u.IDENTIFICACION,
           TRIM(regexp_replace(
               concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE, u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO),
               '\s+', ' ', 'g')),
           su.TLV_ESTADO::text,
           s.PK_TASIGNATURA, s.NOMBRE,
           g.PK_TGRADO, g.NOMBRE,
           gr.PK_TGRUPO, gr.NOMBRE,
           jor.PK_LISTA_VALOR, jor.NOMBRE,
           count(*) OVER()::BIGINT
      FROM academico_test.TDOCENTE_ASIGNATURA da
      JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = da.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TGRUPO gr              ON gr.PK_TGRUPO = da.FK_TGRUPO
      JOIN academico_test.TGRADO g               ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TLISTA_VALOR jor       ON jor.PK_LISTA_VALOR = gr.FK_TLV_JORNADA
      JOIN academico_test.TASIGNATURA s          ON s.PK_TASIGNATURA = da.FK_TASIGNATURA
      JOIN academico_test.TFUNCIONARIO f         ON f.PK_TFUNCIONARIO = da.FK_TFUNCIONARIO
      JOIN academico_test.TUSUARIO u             ON u.PK_TUSUARIO = f.FK_TUSUARIO
 LEFT JOIN academico_test.TSEDE_USUARIO su        ON su.FK_TUSUARIO = u.PK_TUSUARIO
                                                  AND su.FK_TSEDE = pa.FK_TSEDE
                                                  AND su.FK_TROL = 14 AND su.ACTIVE = TRUE
     WHERE da.FK_TPERIODO_ACADEMICO = p_fk_periodo AND da.ACTIVE = TRUE
       AND academico_test.fn_periodo_usuario_puede_ver(p_pk_usuario, p_fk_periodo)
       AND (p_fk_funcionario IS NULL OR CARDINALITY(p_fk_funcionario) = 0 OR f.PK_TFUNCIONARIO = ANY(p_fk_funcionario))
       AND (p_fk_grado       IS NULL OR CARDINALITY(p_fk_grado)       = 0 OR g.PK_TGRADO      = ANY(p_fk_grado))
       AND (p_fk_asignatura  IS NULL OR CARDINALITY(p_fk_asignatura)  = 0 OR s.PK_TASIGNATURA = ANY(p_fk_asignatura))
       AND (p_fk_jornada     IS NULL OR CARDINALITY(p_fk_jornada)     = 0 OR jor.PK_LISTA_VALOR = ANY(p_fk_jornada))
       AND (NULLIF(TRIM(p_estado), '') IS NULL OR su.TLV_ESTADO = p_estado)
     ORDER BY g.NOMBRE, gr.NOMBRE, s.NOMBRE, u.PRIMER_APELLIDO
     LIMIT NULLIF(p_page_size, 0)
    OFFSET COALESCE(p_page_index, 0) * COALESCE(NULLIF(p_page_size, 0), 0);
$$;

-- =============================================================================
-- 5 filas de public.query, una por reporte. Los UUIDs son los que ya estaban
-- sembrados a mano en el servidor de test (`q-mt9...`); `ON CONFLICT DO NOTHING`
-- garantiza que un entorno donde ya estan queda igual y uno desde cero las
-- obtiene. Sin el bloque de `reporting.reports.*` en
-- `reporting-service/src/main/resources/application.yml` (commit aparte) el
-- gateway responde 200 pero el reporting-service devuelve 404; la fila en `query`
-- es necesaria para que el filtro de roles (`role_query` abajo) y el gate del
-- query-service (`fn_periodo_usuario_puede_ver`) corran correctamente.
--
-- "Exportar seleccionados" (patron V69): la misma fila de query con un
-- parametro adicional `BODY.FILTERS.IDS BIGINT[]` y un WHERE por fuera que
-- recorta despues del gate de autorizacion. Asi, mandar el id de una fila
-- que el usuario no puede ver no la revela — el gate ya filtro antes.
--
-- Que columna id usa cada WHERE — cada funcion devuelve un id distinto:
--   fn_area_subject_reporte_listar -> area_id
--   fn_escala_listar               -> id (alias agregado: la fila es
--                                     id_de_la_escala_de_valoracion)
--   fn_plan_reporte_listar         -> id (= PK_TASIGNATURA_PLAN)
--   fn_grado_grupo_reporte_listar  -> grado_id (la pantalla tilda grados,
--                                     no grupos — filtrar por grado
--                                     mantiene el "una fila por grupo")
--   fn_asignacion_reporte_listar   -> docente_id (la pantalla tilda
--                                     filas de asignacion; "docente_id" es
--                                     el id del docente para que exportar
--                                     seleccionado por docente funcione)
-- =============================================================================

-- /areas/reporte → fn_area_subject_reporte_listar
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, detail, path_template, execution_mode, http_method, microservice_id, param_types)
VALUES (
    'q-mt9244pe-lfglm5gw',
    $sql$SELECT * FROM academico_test.fn_area_subject_reporte_listar(
      CAST(:BODY.FILTERS.FK_PERIODO AS BIGINT),
      CAST(:BODY.FILTERS.FK_AREA AS BIGINT[]),
      CAST(:BODY.FILTERS.FK_ASIGNATURA AS BIGINT[]),
      CAST(:BODY.FILTERS.FK_ESPECIALIDAD AS BIGINT[]),
      CAST(:BODY.FILTERS.INCLUIR_INACTIVOS AS BOOLEAN),
      public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
      NULL::INTEGER, NULL::INTEGER
  ) t
WHERE CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
   OR t.area_id = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[]));$sql$,
    'postgres', false, false,
    'V135 — areas/reporte: una fila por (area, asignatura, enfasis). Replica fn_periodo_areas_asignaturas_listar pero con salida fila-plana para el reporte. inactivos excluidos por defecto (param INCLUIR_INACTIVOS=false). WHERE por ids (V69) sobre area_id.',
    '/areas/reporte', 'SELECT', 'POST',
    (SELECT id_microservice FROM public.microservice WHERE serviceid = 'eval-col'),
    '{"BODY.FILTERS.FK_PERIODO": "BIGINT", "BODY.FILTERS.FK_AREA": "BIGINT[]", "BODY.FILTERS.FK_ASIGNATURA": "BIGINT[]", "BODY.FILTERS.FK_ESPECIALIDAD": "BIGINT[]", "BODY.FILTERS.INCLUIR_INACTIVOS": "BOOLEAN", "BODY.FILTERS.IDS": "BIGINT[]"}'
)
ON CONFLICT (uuid) DO NOTHING;

-- /escalas/reporte → fn_escala_listar (funcion existente, reusada)
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, detail, path_template, execution_mode, http_method, microservice_id, param_types)
VALUES (
    'q-mt922y68-ywxkdbfi',
    $sql$SELECT * FROM academico_test.fn_escala_listar(
      CAST(:BODY.FILTERS.FK_PERIODO AS BIGINT),
      NULL::TEXT,
      public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
      CAST(:BODY.FILTERS.FK_NIVEL AS BIGINT),
      NULL::TEXT, NULL::TEXT,
      CAST(:BODY.FILTERS.TIPO AS TEXT)
  ) t
WHERE CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
   OR t.id = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[]));$sql$,
    'postgres', false, false,
    'V135 — escalas/reporte: reusa fn_escala_listar (V42/V97) con FK_PERIODO/FK_NIVEL/TIPO, page_size NULL. WHERE por ids (V69) sobre t.id (alias de la escala_de_valoracion en la salida).',
    '/escalas/reporte', 'SELECT', 'POST',
    (SELECT id_microservice FROM public.microservice WHERE serviceid = 'eval-col'),
    '{"BODY.FILTERS.FK_PERIODO": "BIGINT", "BODY.FILTERS.FK_NIVEL": "BIGINT", "BODY.FILTERS.TIPO": "TEXT", "BODY.FILTERS.IDS": "BIGINT[]"}'
)
ON CONFLICT (uuid) DO NOTHING;

-- /plan-estudio/reporte → fn_plan_reporte_listar (definida en V136,
-- fusionada al rebasear feature/CU-86e2427dp). Acuamontamos la fila de query;
-- la funcion la aporta V136 — sin esa migracion aplicada, este INSERT crea
-- una fila que apunta a una funcion inexistente y el reporte falla 500.
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, detail, path_template, execution_mode, http_method, microservice_id, param_types)
VALUES (
    'q-mt925c80-zy0mfug8',
    $sql$SELECT * FROM academico_test.fn_plan_reporte_listar(
      CAST(:BODY.FILTERS.FK_PERIODO AS BIGINT),
      CAST(:BODY.FILTERS.FK_GRADO AS BIGINT[]),
      CAST(:BODY.FILTERS.FK_ASIGNATURA AS BIGINT[]),
      CAST(:BODY.FILTERS.FK_ESPECIALIDAD AS BIGINT[]),
      public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
      NULL::INTEGER, NULL::INTEGER
  ) t
WHERE CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
   OR t.id = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[]));$sql$,
    'postgres', false, false,
    'V135 — plan-estudio/reporte: una fila por (grado, asignatura, plan). Reusa fn_plan_reporte_listar (V136) con FK_PERIODO/FK_GRADO[]/FK_ASIGNATURA[]/FK_ESPECIALIDAD[]. page_size NULL. WHERE por ids (V69) sobre t.id (= PK_TASIGNATURA_PLAN).',
    '/plan-estudio/reporte', 'SELECT', 'POST',
    (SELECT id_microservice FROM public.microservice WHERE serviceid = 'eval-col'),
    '{"BODY.FILTERS.FK_PERIODO": "BIGINT", "BODY.FILTERS.FK_GRADO": "BIGINT[]", "BODY.FILTERS.FK_ASIGNATURA": "BIGINT[]", "BODY.FILTERS.FK_ESPECIALIDAD": "BIGINT[]", "BODY.FILTERS.IDS": "BIGINT[]"}'
)
ON CONFLICT (uuid) DO NOTHING;

-- /grados/reporte → fn_grado_grupo_reporte_listar
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, detail, path_template, execution_mode, http_method, microservice_id, param_types)
VALUES (
    'q-mt9263nn-nagskpcd',
    $sql$SELECT * FROM academico_test.fn_grado_grupo_reporte_listar(
      CAST(:BODY.FILTERS.FK_PERIODO AS BIGINT),
      CAST(:BODY.FILTERS.FK_GRADO AS BIGINT[]),
      public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
      NULL::INTEGER, NULL::INTEGER
  ) t
WHERE (CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
       OR t.grado_id = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[])))
  AND (CAST(:BODY.FILTERS.GRUPO_IDS AS BIGINT[]) IS NULL
       OR t.grupo_id = ANY(CAST(:BODY.FILTERS.GRUPO_IDS AS BIGINT[])));$sql$,
    'postgres', false, false,
    'V135 — grados/reporte: una fila por (grado, grupo) con director, jornada y plan. fn_grado_grupo_reporte_listar (V135) usa LEFT JOIN contra TGRUPO, de modo que grados sin grupos cargados aparecen igual. WHERE por ids (V69) sobre grado_id (la pantalla tilda GRADOS, no grupos — filtrar por grado deja "una fila por grupo" sin perder filas del grado tildado).',
    '/grados/reporte', 'SELECT', 'POST',
    (SELECT id_microservice FROM public.microservice WHERE serviceid = 'eval-col'),
    '{"BODY.FILTERS.FK_PERIODO": "BIGINT", "BODY.FILTERS.FK_GRADO": "BIGINT[]", "BODY.FILTERS.IDS": "BIGINT[]", "BODY.FILTERS.GRUPO_IDS": "BIGINT[]"}'
)
ON CONFLICT (uuid) DO NOTHING;

-- /asignaciones/reporte → fn_asignacion_reporte_listar
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, detail, path_template, execution_mode, http_method, microservice_id, param_types)
VALUES (
    'q-mt91xbrs-geg8uo0r',
    $sql$SELECT * FROM academico_test.fn_asignacion_reporte_listar(
      CAST(:BODY.FILTERS.FK_PERIODO AS BIGINT),
      CAST(:BODY.FILTERS.FK_FUNCIONARIO AS BIGINT[]),
      CAST(:BODY.FILTERS.FK_GRADO AS BIGINT[]),
      CAST(:BODY.FILTERS.FK_ASIGNATURA AS BIGINT[]),
      CAST(:BODY.FILTERS.FK_JORNADA AS BIGINT[]),
      CAST(:BODY.FILTERS.ESTADO AS TEXT),
      public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
      NULL::INTEGER, NULL::INTEGER
  ) t
WHERE CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
   OR t.docente_id = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[]));$sql$,
    'postgres', false, false,
    'V135 — asignaciones/reporte: una fila por asignacion docente-grado-grupo-asignatura-jornada. LEFT JOIN TSEDE_USUARIO filtra solo docentes con sede activa (rol Docente=14). WHERE por ids (V69) sobre docente_id.',
    '/asignaciones/reporte', 'SELECT', 'POST',
    (SELECT id_microservice FROM public.microservice WHERE serviceid = 'eval-col'),
    '{"BODY.FILTERS.FK_PERIODO": "BIGINT", "BODY.FILTERS.FK_FUNCIONARIO": "BIGINT[]", "BODY.FILTERS.FK_GRADO": "BIGINT[]", "BODY.FILTERS.FK_ASIGNATURA": "BIGINT[]", "BODY.FILTERS.FK_JORNADA": "BIGINT[]", "BODY.FILTERS.ESTADO": "TEXT", "BODY.FILTERS.IDS": "BIGINT[]"}'
)
ON CONFLICT (uuid) DO NOTHING;

-- =============================================================================
-- role_query: copiar los role_query de la query de LISTADO de cada dominio
-- hacia su reporte. Misma regla V67/V124: "quien ve el listado puede
-- exportarlo". Si el query de listado no existe (no deberia pasar — son
-- los de V37/V38/V40/V42/V43/V44/V46), el ON CONFLICT DO NOTHING no
-- rompe y la fila de reporte queda sin permisos hasta que se asigne a mano.
-- =============================================================================
-- Idempotencia "round 2": los INSERT de arriba usan `ON CONFLICT (uuid) DO
-- NOTHING`, asi que si la fila YA estaba sembrada (caso normal: alguien
-- las creo a mano contra el server de test antes de que se redactara
-- esta migracion) el INSERT es noop y los cambios al query / param_types
-- NO se aplican. Por eso este bloque UPDATE las pisa: reemplaza el
-- query (para agregar el WHERE por ids) y le suma la clave
-- BODY.FILTERS.IDS al param_types. UPDATE sobre `uuid` no rompe nada en
-- un entorno limpio (las filas las acabamos de insertar arriba) ni en
-- uno donde ya estaban (las trae al estado actual de esta migracion).
-- =============================================================================
UPDATE public.query SET
    query = $sql$SELECT * FROM academico_test.fn_area_subject_reporte_listar(
      CAST(:BODY.FILTERS.FK_PERIODO AS BIGINT),
      CAST(:BODY.FILTERS.FK_AREA AS BIGINT[]),
      CAST(:BODY.FILTERS.FK_ASIGNATURA AS BIGINT[]),
      CAST(:BODY.FILTERS.FK_ESPECIALIDAD AS BIGINT[]),
      CAST(:BODY.FILTERS.INCLUIR_INACTIVOS AS BOOLEAN),
      public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
      NULL::INTEGER, NULL::INTEGER
  ) t
WHERE CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
   OR t.area_id = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[]))$sql$,
    param_types = param_types || '{"BODY.FILTERS.IDS": "BIGINT[]"}'::JSONB
 WHERE uuid = 'q-mt9244pe-lfglm5gw';

UPDATE public.query SET
    query = $sql$SELECT * FROM academico_test.fn_escala_listar(
      CAST(:BODY.FILTERS.FK_PERIODO AS BIGINT),
      NULL::TEXT,
      public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
      CAST(:BODY.FILTERS.FK_NIVEL AS BIGINT),
      NULL::TEXT, NULL::TEXT,
      CAST(:BODY.FILTERS.TIPO AS TEXT)
  ) t
WHERE CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
   OR t.id = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[]))$sql$,
    param_types = param_types || '{"BODY.FILTERS.IDS": "BIGINT[]"}'::JSONB
 WHERE uuid = 'q-mt922y68-ywxkdbfi';

UPDATE public.query SET
    query = $sql$SELECT * FROM academico_test.fn_plan_reporte_listar(
      CAST(:BODY.FILTERS.FK_PERIODO AS BIGINT),
      CAST(:BODY.FILTERS.FK_GRADO AS BIGINT[]),
      CAST(:BODY.FILTERS.FK_ASIGNATURA AS BIGINT[]),
      CAST(:BODY.FILTERS.FK_ESPECIALIDAD AS BIGINT[]),
      public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
      NULL::INTEGER, NULL::INTEGER
  ) t
WHERE CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
   OR t.id = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[]))$sql$,
    param_types = param_types || '{"BODY.FILTERS.IDS": "BIGINT[]"}'::JSONB
 WHERE uuid = 'q-mt925c80-zy0mfug8';

UPDATE public.query SET
    query = $sql$SELECT * FROM academico_test.fn_grado_grupo_reporte_listar(
      CAST(:BODY.FILTERS.FK_PERIODO AS BIGINT),
      CAST(:BODY.FILTERS.FK_GRADO AS BIGINT[]),
      public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
      NULL::INTEGER, NULL::INTEGER
  ) t
WHERE (CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
       OR t.grado_id = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[])))
  AND (CAST(:BODY.FILTERS.GRUPO_IDS AS BIGINT[]) IS NULL
       OR t.grupo_id = ANY(CAST(:BODY.FILTERS.GRUPO_IDS AS BIGINT[])))$sql$,
    param_types = param_types || '{"BODY.FILTERS.IDS": "BIGINT[]", "BODY.FILTERS.GRUPO_IDS": "BIGINT[]"}'::JSONB
 WHERE uuid = 'q-mt9263nn-nagskpcd';

UPDATE public.query SET
    query = $sql$SELECT * FROM academico_test.fn_asignacion_reporte_listar(
      CAST(:BODY.FILTERS.FK_PERIODO AS BIGINT),
      CAST(:BODY.FILTERS.FK_FUNCIONARIO AS BIGINT[]),
      CAST(:BODY.FILTERS.FK_GRADO AS BIGINT[]),
      CAST(:BODY.FILTERS.FK_ASIGNATURA AS BIGINT[]),
      CAST(:BODY.FILTERS.FK_JORNADA AS BIGINT[]),
      CAST(:BODY.FILTERS.ESTADO AS TEXT),
      public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
      NULL::INTEGER, NULL::INTEGER
  ) t
WHERE CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
   OR t.docente_id = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[]))$sql$,
    param_types = param_types || '{"BODY.FILTERS.IDS": "BIGINT[]"}'::JSONB
 WHERE uuid = 'q-mt91xbrs-geg8uo0r';
-- =============================================================================
INSERT INTO public.role_query (query_id, role_id)
SELECT reporte.id_query, rq.role_id
  FROM public.query reporte
  JOIN (VALUES
        ('q-mt9244pe-lfglm5gw', '/areas/query'),
        ('q-mt922y68-ywxkdbfi', '/escalas/query'),
        ('q-mt925c80-zy0mfug8', '/plan-asignaturas-disponibles/query'),
        ('q-mt9263nn-nagskpcd', '/grados/query'),
        ('q-mt91xbrs-geg8uo0r', '/asignaciones/query')
       ) AS m (uuid_reporte, path_listado)
    ON reporte.uuid = m.uuid_reporte
  JOIN public.query listado
    ON listado.path_template = m.path_listado
   AND listado.http_method   = 'POST'
  JOIN public.role_query rq ON rq.query_id = listado.id_query
ON CONFLICT (query_id, role_id) DO NOTHING;