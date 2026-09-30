-- ===========================================================================
-- V396 — fn_sed_listar_todos_planeador + GET /planeador/sedes/opciones.
--
-- El select liviano de sedes de fn_sed_listar_todos (V52), pero con el gate
-- del grupo del sidebar que contiene a PLANEADOR y no el de SEDES_EDUCATIVAS:
-- rector y coordinador tienen el grupo aunque no tengan el submenu. El grupo
-- se resuelve por estructura (fn_menu_grupo_de) y el codigo se compara en
-- forma canonica, asi que no depende de como este escrito en cada ambiente.
--
-- Depende de: V29 (fn_assert_permiso_seccion, fn_menu_codigo_canonico,
-- fn_usuario_sedes_lectura), V52 y V216.
-- ===========================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_menu_grupo_de(
    p_codigo_hijo VARCHAR
)
RETURNS VARCHAR
LANGUAGE sql
STABLE
AS $$
    SELECT padre.CODIGO
      FROM academico_test.TMENU hijo
      JOIN academico_test.TMENU padre
        ON padre.PK_TMENU = hijo.FK_TMENU
     WHERE academico_test.fn_menu_codigo_canonico(hijo.CODIGO)
         = academico_test.fn_menu_codigo_canonico(p_codigo_hijo)
       AND hijo.ACTIVE  = TRUE
       AND padre.ACTIVE = TRUE
     ORDER BY padre.PK_TMENU
     LIMIT 1;
$$;

COMMENT ON FUNCTION academico_test.fn_menu_grupo_de(VARCHAR)
    IS 'CODIGO del menu PADRE (grupo del sidebar) del submenu identificado por p_codigo_hijo, comparado en forma canonica (fn_menu_codigo_canonico). Devuelve el CODIGO literal de la fila, que es lo que fn_usuario_puede_en_menu compara exacto, asi que el gate deja de depender de si el grupo esta escrito con tildes o sin ellas. NULL si el submenu no existe, esta inactivo o no tiene padre activo: el caller falla cerrado (fn_usuario_puede_en_menu con menu NULL devuelve FALSE). V396.';


-- ---------------------------------------------------------------------------
-- 1. Funcion
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_sed_listar_todos_planeador(BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_sed_listar_todos_planeador(p_pk_usuario_solicitante bigint)
 RETURNS TABLE(pk_sede bigint, codigo character varying, nombre character varying, fk_tlv_zona bigint, zona_nombre character varying, barrio character varying, comuna character varying, direccion character varying, telefono character varying, fk_establecimiento bigint)
 LANGUAGE plpgsql
 STABLE
AS $$
BEGIN
    -- Gate: capability 'VER' sobre el GRUPO al que cuelga PLANEADOR (Gestion
    -- Academica; ver DECISION y CORRECCION en la cabecera). El codigo del
    -- grupo se resuelve por estructura (fn_menu_grupo_de) y se compara en
    -- forma canonica, para no depender de si la fila quedo con tildes o sin
    -- ellas en cada ambiente. fn_assert_permiso_seccion hace bypass del
    -- nivel 0 y lanza 42501 si el usuario no puede; si el grupo no se puede
    -- resolver llega NULL y tambien lanza 42501 (fail-closed). El scope de
    -- lectura lo pone el JOIN de abajo.
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante,
        academico_test.fn_menu_grupo_de('PLANEADOR'),
        'VER'
    );

    RETURN QUERY
    SELECT s.PK_TSEDE, s.CODIGO, s.NOMBRE, s.FK_TLV_ZONA, tlv.NOMBRE,
           s.BARRIO, s.COMUNA, s.DIRECCION, s.TELEFONO, s.FK_TESTABLECIMIENTO
      FROM academico_test.TSEDE s
      JOIN academico_test.fn_usuario_sedes_lectura(p_pk_usuario_solicitante) sl
        ON sl.sede_id = s.PK_TSEDE
 LEFT JOIN academico_test.TLISTA_VALOR tlv ON tlv.PK_LISTA_VALOR = s.FK_TLV_ZONA
     WHERE s.ACTIVE = TRUE
     ORDER BY s.NOMBRE ASC, s.PK_TSEDE ASC;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_sed_listar_todos_planeador(BIGINT)
    IS 'Copia de fn_sed_listar_todos (V52) con gate VER sobre el grupo de menu padre de PLANEADOR (Gestion Academica), resuelto por estructura con fn_menu_grupo_de y comparado en forma canonica (sin tildes), en vez de SEDES_EDUCATIVAS. Lista TODAS las TSEDE activas que el usuario puede ver (fn_usuario_sedes_lectura), sin paginar, con las columnas necesarias para armar un `Campus` del front mas su EE. Si el usuario no tiene la capability => 42501. V396.';


-- ---------------------------------------------------------------------------
-- 2. GET /planeador/sedes/opciones  ->  fn_sed_listar_todos_planeador
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'eval-col-planeador-sedes-opciones-001',
    'SELECT * FROM academico_test.fn_sed_listar_todos_planeador(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/planeador/sedes/opciones', 'SELECT', 'GET',
    '{}'::jsonb,
    NULL,
    'V396 -- Gemelo de GET /establecimientos/sedes/opciones para el PLANEADOR: lista liviana (id+nombre+establecimiento, mas codigo/zona/barrio/comuna/direccion/telefono) de todas las sedes que el usuario puede ver (fn_usuario_sedes_lectura), sin paginar, para los selects/filtros del planeador. Gate VER sobre el grupo de menu al que cuelga PLANEADOR (Gestion Academica, resuelto por estructura con fn_menu_grupo_de) en vez de SEDES_EDUCATIVAS. 42501 si el usuario no tiene la capability.',
    'planeador-sedes-opciones', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

-- Roles JWT = roles con el grupo Gestion Academica + SSO-ADMIN.
INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-COORDINADOR', 'CEVAL-DOCENTE', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/planeador/sedes/opciones'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- La fila ya existia en los ambientes donde corrio la primera version de V396
-- (gate PLANEADOR): el INSERT de arriba es DO NOTHING, asi que el detail se
-- reconcilia aparte para que documente el gate real.
UPDATE public.query q
   SET detail = 'V396 -- Gemelo de GET /establecimientos/sedes/opciones para el PLANEADOR: lista liviana (id+nombre+establecimiento, mas codigo/zona/barrio/comuna/direccion/telefono) de todas las sedes que el usuario puede ver (fn_usuario_sedes_lectura), sin paginar, para los selects/filtros del planeador. Gate VER sobre el grupo de menu al que cuelga PLANEADOR (Gestion Academica, resuelto por estructura con fn_menu_grupo_de) en vez de SEDES_EDUCATIVAS. 42501 si el usuario no tiene la capability.'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/sedes/opciones'
   AND q.http_method     = 'GET'
   AND q.detail IS DISTINCT FROM 'V396 -- Gemelo de GET /establecimientos/sedes/opciones para el PLANEADOR: lista liviana (id+nombre+establecimiento, mas codigo/zona/barrio/comuna/direccion/telefono) de todas las sedes que el usuario puede ver (fn_usuario_sedes_lectura), sin paginar, para los selects/filtros del planeador. Gate VER sobre el grupo de menu al que cuelga PLANEADOR (Gestion Academica, resuelto por estructura con fn_menu_grupo_de) en vez de SEDES_EDUCATIVAS. 42501 si el usuario no tiene la capability.';
