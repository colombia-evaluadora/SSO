-- V500 -- corrige el estado de POST /usuarios/actividad/query (V495): CON_INGRESO si el usuario tiene
-- alguna sesion registrada, SIN_INGRESO si no; EN_LINEA/DESCONECTADO desaparecen.
-- pigse.fn_sesion_usuario lleva una fila de tsesion_web al pigse.tusuario dueno: por fk_id_user (V495)
-- o, en sesiones previas, por fk_tusuario -> TUSUARIO.CUENTA = users.email -> fn_get_pigse_usuario_id.
-- Firma y wrapper del endpoint sin cambios. Depende de: V495, V261 (fn_get_pigse_usuario_id).

CREATE OR REPLACE FUNCTION pigse.fn_sesion_usuario(p_fk_tusuario BIGINT, p_fk_id_user BIGINT)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT public.fn_get_pigse_usuario_id(COALESCE(
        p_fk_id_user,
        (SELECT u.id_user
           FROM academico_test.tusuario t
           JOIN public.users u ON u.email = t.cuenta
          WHERE t.pk_tusuario = p_fk_tusuario)
    ))
$$;

COMMENT ON FUNCTION pigse.fn_sesion_usuario(BIGINT, BIGINT) IS
    'V500: pk de pigse.tusuario dueno de una fila de academico_test.tsesion_web, o NULL. Usa fk_id_user (V495) y, si falta, el puente academico TUSUARIO.CUENTA = public.users.email (paso 1 de fn_get_academico_usuario_id). Resolver el actor: pigse.fn_resolver_actor(pigse.fn_sesion_usuario(...)).';

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
    IF v_estado IS NOT NULL AND v_estado NOT IN ('CON_INGRESO', 'SIN_INGRESO') THEN
        RAISE EXCEPTION 'estado invalido: % (CON_INGRESO o SIN_INGRESO)', p_estado
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
    pares AS (
        SELECT s.fk_tusuario, s.fk_id_user,
               MAX(s.started_at)   AS ultimo_login,
               MAX(s.last_seen_at) AS ultima_actividad
          FROM academico_test.tsesion_web s
         GROUP BY s.fk_tusuario, s.fk_id_user
    ),
    actividad AS (
        SELECT pigse.fn_sesion_usuario(p.fk_tusuario, p.fk_id_user) AS pk_tusuario,
               MAX(p.ultimo_login)     AS ultimo_login,
               MAX(p.ultima_actividad) AS ultima_actividad
          FROM pares p
         GROUP BY 1
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
               CASE WHEN a.ultimo_login IS NULL THEN 'SIN_INGRESO' ELSE 'CON_INGRESO' END AS estado
          FROM pigse.TUSUARIO u
          LEFT JOIN vinculos_activos va ON va.fk_tusuario = u.PK_TUSUARIO
          LEFT JOIN actividad a ON a.pk_tusuario = u.PK_TUSUARIO
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
    'V500: nucleo sin permisos. Una fila por (establecimiento, usuario PIGSE activo); quien no tiene EE sale con establecimiento NULL. Actividad = academico_test.tsesion_web resuelta a pigse.tusuario con pigse.fn_sesion_usuario. estado: CON_INGRESO (alguna sesion registrada) o SIN_INGRESO.';

UPDATE public.query
   SET detail = 'Actividad de usuarios PIGSE por establecimiento: ultimo ingreso, ultima actividad y estado CON_INGRESO/SIN_INGRESO, paginado. Lee academico_test.tsesion_web en Postgres, no ClickHouse; no es /audits/query (sesiones de auditoria).'
 WHERE uuid = '0c6f1e4a-7b2d-4d51-9a38-5e2f9b7c4d95';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = '0c6f1e4a-7b2d-4d51-9a38-5e2f9b7c4d95') THEN
        RAISE EXCEPTION 'V500: falta POST /usuarios/actividad/query (V495)';
    END IF;
END $$;
