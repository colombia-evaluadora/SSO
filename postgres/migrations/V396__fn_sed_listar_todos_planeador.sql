-- ===========================================================================
-- V396 — fn_sed_listar_todos_planeador + GET /planeador/sedes/opciones
--
-- Copia de academico_test.fn_sed_listar_todos (V52) -- la funcion que sirve
-- GET /establecimientos/sedes/opciones (V95) -- pero con el gate del
-- PLANEADOR en lugar del de SEDES_EDUCATIVAS, y su endpoint gemelo en
-- public.query bajo /planeador/sedes/opciones.
--
-- Motivo: el planeador necesita el mismo select liviano de sedes (id+nombre+
-- establecimiento) para sus filtros, pero un docente con acceso al PLANEADOR
-- no tiene necesariamente la capability VER sobre SEDES_EDUCATIVAS, asi que
-- fn_sed_listar_todos le responde 42501.
--
-- Diferencias respecto a fn_sed_listar_todos:
--   * Gate: fn_assert_permiso_seccion(usuario, 'PLANEADOR', 'VER'), el mismo
--     helper (V29) que usa todo el modulo planeador (V216/V224/V277). Hace
--     bypass del SUPER_ADMIN (nivel 0) por dentro, igual que el IF manual de
--     la original.
--   * Nada mas. El alcance de lectura sigue siendo fn_usuario_sedes_lectura,
--     las columnas y el orden son identicos, para que el front pueda reusar el
--     mismo tipo `Campus`.
--
-- Endpoint (misma forma que V95 #6, cambia path, funcion y roles):
--   GET /planeador/sedes/opciones  ->  fn_sed_listar_todos_planeador
--   Sin parametros (solo CONTEXT.USER_ID), sin query_param_constraint.
--   Roles JWT (role_query): los que tienen el menu PLANEADOR en TROL_MENU
--   (COORDINADOR, DOCENTE, RECTOR, SUPER_ADMINISTRADOR) + SSO-ADMIN, para que
--   el gate del JWT y el gate de la base no queden desincronizados (ver
--   memoria "gate dual JWT vs PL/pgSQL"). El gate real es el de la funcion.
--
-- NOTA operativa: la fila nueva de public.query solo se sirve tras reiniciar
-- el contenedor query-service-eval-col (rutas provisionadas al arranque).
--
-- Dependencias:
--   * V29  — fn_assert_permiso_seccion, fn_usuario_sedes_lectura.
--   * V52  — fn_sed_listar_todos (funcion de referencia; no se toca).
--   * V95  — GET /establecimientos/sedes/opciones (endpoint de referencia).
--   * V216 — menu 'PLANEADOR'.
-- ===========================================================================

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
    -- Gate del planeador: capability 'VER' sobre el menu PLANEADOR
    -- (fn_assert_permiso_seccion hace bypass del nivel 0 y lanza 42501
    -- si el usuario no puede). El scope de lectura lo pone el JOIN de abajo.
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
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
    IS 'Copia de fn_sed_listar_todos (V52) con gate VER sobre el menu PLANEADOR en vez de SEDES_EDUCATIVAS. Lista TODAS las TSEDE activas que el usuario puede ver (fn_usuario_sedes_lectura), sin paginar, con las columnas necesarias para armar un `Campus` del front mas su EE. Si el usuario no tiene la capability => 42501. V396.';


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
    'V396 -- Gemelo de GET /establecimientos/sedes/opciones para el PLANEADOR: lista liviana (id+nombre+establecimiento, mas codigo/zona/barrio/comuna/direccion/telefono) de todas las sedes que el usuario puede ver (fn_usuario_sedes_lectura), sin paginar, para los selects/filtros del planeador. Gate VER sobre PLANEADOR (fn_sed_listar_todos_planeador) en vez de SEDES_EDUCATIVAS. 42501 si el usuario no tiene la capability.',
    'planeador-sedes-opciones', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

-- Roles JWT = roles con el menu PLANEADOR (V216 + V305) + SSO-ADMIN.
INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-COORDINADOR', 'CEVAL-DOCENTE', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/planeador/sedes/opciones'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;
