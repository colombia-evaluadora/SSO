-- V495 -- POST /usuarios/actividad/query (pigse): usuarios PIGSE por establecimiento con su ultimo
-- login, ultima actividad y si estan en linea ahora (sesion abierta con actividad en los ultimos 30 min).
-- tsesion_web gana fk_id_user: la sesion solo guardaba fk_tusuario academico y un usuario solo-PIGSE
-- no dejaba fila; auth-center (mismo commit) la abre y la llena con public.users.id_user.
-- Gate: roles SECRETARIA_TERRITORIAL, SECRETARIO, JEFE_AREA_* y ADMINISTRADOR, sin filtro territorial.
-- Depende de: V88/V400 (tsesion_web), V261 (pigse.tusuario), V368 (fila hermana /documentos/todos/query).

ALTER TABLE academico_test.tsesion_web
    ADD COLUMN IF NOT EXISTS fk_id_user BIGINT REFERENCES public.users (id_user) ON DELETE SET NULL;

COMMENT ON COLUMN academico_test.tsesion_web.fk_id_user IS
    'V495: public.users.id_user dueno de la sesion. A diferencia de fk_tusuario (academico_test) existe para cualquier cuenta, incluida la solo-PIGSE. NULL en sesiones anteriores a V495.';

CREATE INDEX IF NOT EXISTS ix_tsesion_web_fk_id_user
    ON academico_test.tsesion_web (fk_id_user, last_seen_at DESC)
    WHERE fk_id_user IS NOT NULL;

CREATE OR REPLACE FUNCTION pigse.fn_usuarios_actividad_listar_interno(
    p_search             VARCHAR DEFAULT NULL,
    p_fk_establecimiento BIGINT  DEFAULT NULL,
    p_estado             VARCHAR DEFAULT NULL,
    p_sort_campo         VARCHAR DEFAULT NULL,
    p_sort_desc          BOOLEAN DEFAULT FALSE,
    p_page_index         INTEGER DEFAULT 0,
    p_page_size          INTEGER DEFAULT 10
)
RETURNS TABLE (rows JSONB, total_count BIGINT, page_count INTEGER, page_index INTEGER, page_size INTEGER)
LANGUAGE plpgsql
STABLE
SET search_path = pigse, public
AS $$
DECLARE
    v_page_size  INTEGER := GREATEST(1, LEAST(COALESCE(p_page_size, 10), 200));
    v_page_index INTEGER := GREATEST(0, COALESCE(p_page_index, 0));
    v_campo      VARCHAR := COALESCE(NULLIF(TRIM(p_sort_campo), ''), 'establecimientoNombre');
    v_desc       BOOLEAN := COALESCE(p_sort_desc, FALSE);
    v_estado     VARCHAR := NULLIF(UPPER(TRIM(p_estado)), '');
    v_search     TEXT    := translate(lower(NULLIF(TRIM(p_search), '')), 'áéíóúüñ', 'aeiouun');
BEGIN
    IF v_estado IS NOT NULL AND v_estado NOT IN ('EN_LINEA', 'DESCONECTADO', 'SIN_INGRESO') THEN
        RAISE EXCEPTION 'estado invalido: % (EN_LINEA, DESCONECTADO o SIN_INGRESO)', p_estado
            USING ERRCODE = '22023';
    END IF;
    IF v_campo NOT IN ('establecimientoNombre', 'nombre', 'ultimoLogin', 'ultimaActividad', 'estado') THEN
        RAISE EXCEPTION 'campo de orden invalido: %', p_sort_campo USING ERRCODE = '22023';
    END IF;

    RETURN QUERY
    WITH vinculos AS (
        SELECT eu.FK_TUSUARIO AS fk_tusuario, eu.FK_TESTABLECIMIENTO AS fk_ee
          FROM pigse.TESTABLECIMIENTO_USUARIO eu
         WHERE eu.ACTIVE AND eu.TLV_ESTADO = 'ACTIVO'
        UNION
        SELECT f.FK_TUSUARIO, f.FK_TESTABLECIMIENTO
          FROM pigse.TFUNCIONARIO f
         WHERE f.ACTIVE AND f.FK_TESTABLECIMIENTO IS NOT NULL
        UNION
        SELECT f.FK_TUSUARIO, e.PK_ESTABLECIMIENTO
          FROM pigse.TESTABLECIMIENTO e
          JOIN pigse.TFUNCIONARIO f
            ON f.PK_TFUNCIONARIO IN (e.FK_TFUNCIONARIO_RECTOR, e.FK_TFUNCIONARIO_SECRETARIA)
         WHERE f.ACTIVE
        UNION
        SELECT su.FK_TUSUARIO, s.FK_TESTABLECIMIENTO
          FROM pigse.TSEDE_USUARIO su
          JOIN pigse.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
         WHERE su.ACTIVE AND s.ACTIVE
    ),
    vinculos_activos AS (
        SELECT v.fk_tusuario, e.PK_ESTABLECIMIENTO, e.CODIGO, e.NOMBRE
          FROM vinculos v
          JOIN pigse.TESTABLECIMIENTO e ON e.PK_ESTABLECIMIENTO = v.fk_ee AND e.ACTIVE
    ),
    actividad AS (
        SELECT s.fk_id_user,
               MAX(s.started_at)   AS ultimo_login,
               MAX(s.last_seen_at) AS ultima_actividad,
               BOOL_OR(s.ended_at IS NULL AND s.last_seen_at > now() - INTERVAL '30 minutes') AS en_linea
          FROM academico_test.tsesion_web s
         WHERE s.fk_id_user IN (SELECT FK_ID_USER FROM pigse.TUSUARIO WHERE ACTIVE)
         GROUP BY s.fk_id_user
    ),
    roles AS (
        SELECT ru.user_id, string_agg(r.name, ',' ORDER BY r.name) AS roles
          FROM public.role_users ru
          JOIN public.role r ON r.id_role = ru.role_id AND r.name LIKE 'PIGSE-%'
         GROUP BY ru.user_id
    ),
    filas AS (
        SELECT va.PK_ESTABLECIMIENTO AS "establecimientoId",
               va.CODIGO             AS "establecimientoCodigo",
               va.NOMBRE             AS "establecimientoNombre",
               u.PK_TUSUARIO         AS "usuarioId",
               concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE, u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO) AS nombre,
               u.IDENTIFICACION      AS identificacion,
               u.CORREO_ELECTRONICO  AS correo,
               ro.roles,
               a.ultimo_login        AS "ultimoLogin",
               a.ultima_actividad    AS "ultimaActividad",
               COALESCE(a.en_linea, FALSE) AS "enLinea",
               CASE WHEN a.en_linea THEN 'EN_LINEA'
                    WHEN a.ultimo_login IS NULL THEN 'SIN_INGRESO'
                    ELSE 'DESCONECTADO' END AS estado
          FROM pigse.TUSUARIO u
          LEFT JOIN vinculos_activos va ON va.fk_tusuario = u.PK_TUSUARIO
          LEFT JOIN actividad a ON a.fk_id_user = u.FK_ID_USER
          LEFT JOIN roles ro ON ro.user_id = u.FK_ID_USER
         WHERE u.ACTIVE
    ),
    filtrada AS (
        SELECT f.*
          FROM filas f
         WHERE (p_fk_establecimiento IS NULL OR f."establecimientoId" = p_fk_establecimiento)
           AND (v_estado IS NULL OR f.estado = v_estado)
           AND (v_search IS NULL
                OR translate(lower(concat_ws(' ', f.nombre, f.identificacion, f.correo,
                                             f."establecimientoNombre", f."establecimientoCodigo")),
                             'áéíóúüñ', 'aeiouun') LIKE '%' || v_search || '%')
    ),
    numerada AS (
        SELECT f.*,
               ROW_NUMBER() OVER (
                   ORDER BY
                       CASE WHEN v_campo = 'establecimientoNombre' AND NOT v_desc THEN f."establecimientoNombre" END ASC NULLS LAST,
                       CASE WHEN v_campo = 'establecimientoNombre' AND v_desc     THEN f."establecimientoNombre" END DESC NULLS LAST,
                       CASE WHEN v_campo = 'nombre'          AND NOT v_desc THEN f.nombre END ASC,
                       CASE WHEN v_campo = 'nombre'          AND v_desc     THEN f.nombre END DESC,
                       CASE WHEN v_campo = 'estado'          AND NOT v_desc THEN f.estado END ASC,
                       CASE WHEN v_campo = 'estado'          AND v_desc     THEN f.estado END DESC,
                       CASE WHEN v_campo = 'ultimoLogin'     AND NOT v_desc THEN f."ultimoLogin" END ASC NULLS LAST,
                       CASE WHEN v_campo = 'ultimoLogin'     AND v_desc     THEN f."ultimoLogin" END DESC NULLS LAST,
                       CASE WHEN v_campo = 'ultimaActividad' AND NOT v_desc THEN f."ultimaActividad" END ASC NULLS LAST,
                       CASE WHEN v_campo = 'ultimaActividad' AND v_desc     THEN f."ultimaActividad" END DESC NULLS LAST,
                       f."establecimientoNombre" ASC NULLS LAST,
                       f.nombre ASC,
                       f."usuarioId" ASC
               ) AS rn
          FROM filtrada f
    ),
    pagina AS (
        SELECT * FROM numerada
         WHERE rn >  v_page_index * v_page_size
           AND rn <= (v_page_index + 1) * v_page_size
    )
    SELECT
        COALESCE((SELECT jsonb_agg(to_jsonb(p) - 'rn' ORDER BY p.rn) FROM pagina p), '[]'::jsonb),
        (SELECT COUNT(*) FROM filtrada),
        GREATEST(1, CEIL((SELECT COUNT(*) FROM filtrada)::numeric / v_page_size)::integer),
        v_page_index,
        v_page_size;
END;
$$;

COMMENT ON FUNCTION pigse.fn_usuarios_actividad_listar_interno(VARCHAR, BIGINT, VARCHAR, VARCHAR, BOOLEAN, INTEGER, INTEGER) IS
    'V495: nucleo sin permisos. Una fila por (establecimiento, usuario PIGSE activo); quien no tiene EE (territoriales) sale con establecimiento NULL. Vinculo = TESTABLECIMIENTO_USUARIO, TFUNCIONARIO, puntero rector/secretaria o TSEDE_USUARIO. Actividad = academico_test.tsesion_web por fk_id_user (V495); EN_LINEA = sesion abierta con last_seen_at en los ultimos 30 min, misma regla que /audits/query.';

CREATE OR REPLACE FUNCTION pigse.fn_usuarios_actividad_listar(
    p_id_user            BIGINT,
    p_search             VARCHAR DEFAULT NULL,
    p_fk_establecimiento BIGINT  DEFAULT NULL,
    p_estado             VARCHAR DEFAULT NULL,
    p_sort_campo         VARCHAR DEFAULT NULL,
    p_sort_desc          BOOLEAN DEFAULT FALSE,
    p_page_index         INTEGER DEFAULT 0,
    p_page_size          INTEGER DEFAULT 10
)
RETURNS TABLE (rows JSONB, total_count BIGINT, page_count INTEGER, page_index INTEGER, page_size INTEGER)
LANGUAGE plpgsql
STABLE
SET search_path = pigse, public
AS $$
BEGIN
    IF p_id_user IS NULL OR NOT EXISTS (
        SELECT 1
          FROM public.role_users ru
          JOIN public.role r ON r.id_role = ru.role_id
         WHERE ru.user_id = p_id_user
           AND r.name IN ('PIGSE-SECRETARIA_TERRITORIAL', 'PIGSE-SECRETARIO',
                          'PIGSE-JEFE_AREA_CALIDAD', 'PIGSE-JEFE_AREA_PLANEACION',
                          'PIGSE-JEFE_AREA_COBERTURA', 'PIGSE-ADMINISTRADOR')
    ) THEN
        RAISE EXCEPTION 'El usuario no tiene permiso para consultar la actividad de usuarios'
            USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    SELECT * FROM pigse.fn_usuarios_actividad_listar_interno(
        p_search, p_fk_establecimiento, p_estado, p_sort_campo, p_sort_desc, p_page_index, p_page_size);
END;
$$;

COMMENT ON FUNCTION pigse.fn_usuarios_actividad_listar(BIGINT, VARCHAR, BIGINT, VARCHAR, VARCHAR, BOOLEAN, INTEGER, INTEGER) IS
    'V495: wrapper de POST /usuarios/actividad/query. Gate por rol PIGSE (secretaria territorial, secretario, jefes de area, administrador) sin alcance territorial; delega en fn_usuarios_actividad_listar_interno.';

DELETE FROM public.query WHERE uuid = '0c6f1e4a-7b2d-4d51-9a38-5e2f9b7c4d95';

INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id, path_template,
                          execution_mode, http_method, param_types, cacheable, detail)
SELECT '0c6f1e4a-7b2d-4d51-9a38-5e2f9b7c4d95',
       $q$SELECT * FROM pigse.fn_usuarios_actividad_listar(
           CAST(:CONTEXT.USER_ID AS BIGINT),
           CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
           CAST(:BODY.FILTERS.ESTABLECIMIENTOID AS BIGINT),
           CAST(:BODY.FILTERS.ESTADO AS VARCHAR),
           CAST(:BODY.SORTING.ID AS VARCHAR),
           CAST(:BODY.SORTING.DESC AS BOOLEAN),
           CAST(:BODY.PAGEINDEX AS INTEGER),
           CAST(:BODY.PAGESIZE AS INTEGER)
       )$q$,
       h.type, h.public_end, h.captcha, h.microservice_id, '/usuarios/actividad/query',
       h.execution_mode, 'POST',
       '{"BODY.PAGESIZE":"INTEGER","BODY.PAGEINDEX":"INTEGER","BODY.SORTING.ID":"VARCHAR","BODY.SORTING.DESC":"BOOLEAN","BODY.FILTERS.SEARCH":"VARCHAR","BODY.FILTERS.ESTABLECIMIENTOID":"BIGINT","BODY.FILTERS.ESTADO":"VARCHAR"}'::jsonb,
       false,
       'Actividad de usuarios PIGSE por establecimiento: ultimo login, ultima actividad y estado EN_LINEA/DESCONECTADO/SIN_INGRESO, paginado. Lee academico_test.tsesion_web en Postgres, no ClickHouse; no es /audits/query (sesiones de auditoria).'
  FROM public.query h
  JOIN public.microservice m ON m.id_microservice = h.microservice_id
 WHERE m.serviceid = 'pigse'
   AND h.path_template = '/documentos/todos/query'
   AND h.http_method = 'POST';

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.role r ON r.name IN ('PIGSE-SECRETARIA_TERRITORIAL', 'PIGSE-SECRETARIO',
                                   'PIGSE-JEFE_AREA_CALIDAD', 'PIGSE-JEFE_AREA_PLANEACION',
                                   'PIGSE-JEFE_AREA_COBERTURA', 'PIGSE-ADMINISTRADOR')
 WHERE q.uuid = '0c6f1e4a-7b2d-4d51-9a38-5e2f9b7c4d95'
ON CONFLICT DO NOTHING;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = '0c6f1e4a-7b2d-4d51-9a38-5e2f9b7c4d95') THEN
        RAISE EXCEPTION 'V495: no se creo POST /usuarios/actividad/query (falta la fila hermana /documentos/todos/query del microservicio pigse)';
    END IF;
END $$;
