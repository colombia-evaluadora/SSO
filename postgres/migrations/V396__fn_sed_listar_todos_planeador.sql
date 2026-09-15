-- ===========================================================================
-- V396 — fn_sed_listar_todos_planeador + GET /planeador/sedes/opciones
--
-- Copia de academico_test.fn_sed_listar_todos (V52) -- la funcion que sirve
-- GET /establecimientos/sedes/opciones (V95) -- pero con el gate del
-- grupo Gestion Academica (el padre de Planeador y Asistencias en el
-- sidebar) en lugar del de SEDES_EDUCATIVAS, y su endpoint gemelo en
-- public.query bajo /planeador/sedes/opciones.
--
-- Motivo: el planeador necesita el mismo select liviano de sedes (id+nombre+
-- establecimiento) para sus filtros, pero un docente/rector con acceso a
-- Gestion Academica no tiene necesariamente la capability VER sobre
-- SEDES_EDUCATIVAS, asi que fn_sed_listar_todos le responde 42501.
--
-- DECISION (usuario, 2026-09-14): el gate es el menu PADRE de Planeador y no
-- el hijo 'PLANEADOR'. En el servidor de test el submenu PLANEADOR solo lo
-- tienen DOCENTE y SUPER_ADMINISTRADOR, mientras que RECTOR/COORDINADOR
-- tienen el grupo (con Asistencias) y tambien necesitan este select. Queda
-- explicitamente aceptado que difiere del resto de endpoints /planeador/*
-- (gate 'PLANEADOR') y que basta el grupo para listar sedes.
--
-- CORRECCION (usuario, 2026-09-15): la primera version de este gate pasaba el
-- literal 'GESTIÓN_ACÁDEMICA' (con tildes) a fn_assert_permiso_seccion. En
-- PRODUCCION ese menu (pk_tmenu=18, created_by='migracion') tiene
-- CODIGO='GESTION_ACADEMICA', SIN tildes, y fn_usuario_puede_en_menu compara
-- el CODIGO **exacto** -> ningun usuario salvo el nivel 0 pasaba el gate y
-- GET /planeador/sedes/opciones respondia 42501/FORBIDDEN incluso a docentes
-- cuyo fn_usuario_permisos_menu listaba GESTION_ACADEMICA con puede_ver=TRUE.
--
-- Por eso el gate ya NO depende de como este escrito el texto del grupo:
--   * fn_menu_codigo_canonico  normaliza (UPPER + TRIM + sin tildes), asi que
--     'GESTIÓN_ACÁDEMICA', 'Gestion_Academica' y 'GESTION_ACADEMICA' son el
--     mismo codigo. No se usa la extension unaccent: no esta instalada en el
--     servidor (solo pg_trgm/pgcrypto/plpgsql), se hace con translate().
--   * fn_menu_grupo_de('PLANEADOR') resuelve el grupo por ESTRUCTURA
--     (TMENU.FK_TMENU, el padre del submenu) en vez de por su texto. El unico
--     literal que queda es 'PLANEADOR', que es estable y ya lo usan V216/
--     V224/V277 para el resto del modulo.
-- Ambos helpers son fail-closed: si el menu no existe devuelven NULL, y
-- fn_assert_permiso_seccion con menu NULL da FALSE -> 42501, como antes.
--
-- Diferencias respecto a fn_sed_listar_todos:
--   * Gate: fn_assert_permiso_seccion(usuario, fn_menu_grupo_de('PLANEADOR'),
--     'VER'), el mismo helper (V29) que usa el modulo planeador (V216/V224/
--     V277). Hace bypass del SUPER_ADMIN (nivel 0) por dentro, igual que el
--     IF manual de la original.
--   * Nada mas. El alcance de lectura sigue siendo fn_usuario_sedes_lectura,
--     las columnas y el orden son identicos, para que el front pueda reusar el
--     mismo tipo `Campus`.
--
-- Endpoint (misma forma que V95 #6, cambia path, funcion y roles):
--   GET /planeador/sedes/opciones  ->  fn_sed_listar_todos_planeador
--   Sin parametros (solo CONTEXT.USER_ID), sin query_param_constraint.
--   Roles JWT (role_query): los que tienen el grupo Gestion Academica en
--   TROL_MENU (COORDINADOR, DOCENTE, RECTOR, SUPER_ADMINISTRADOR) + SSO-ADMIN, para que
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
--   * V216 — modulo planeador (fn_assert_permiso_seccion como gate).
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 0. Helpers de resolucion de menu (ver CORRECCION en la cabecera).
--    Viven aqui y no en V29 porque V29 ya corrio en todos los ambientes y
--    estos helpers solo los necesita este gate por ahora; si otro modulo los
--    reusa, mueranse a un helper comun.
-- ---------------------------------------------------------------------------

-- 0.a Forma canonica de un CODIGO de menu: mayusculas, sin espacios al borde
--     y sin tildes. translate() en vez de unaccent porque la extension no
--     esta instalada (pg_trgm / pgcrypto / plpgsql son las unicas).
CREATE OR REPLACE FUNCTION academico_test.fn_menu_codigo_canonico(
    p_codigo VARCHAR
)
RETURNS VARCHAR
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT UPPER(TRIM(translate(
        COALESCE(p_codigo, ''),
        'ÁÀÄÂáàäâÉÈËÊéèëêÍÌÏÎíìïîÓÒÖÔóòöôÚÙÜÛúùüûÑñÇç',
        'AAAAaaaaEEEEeeeeIIIIiiiiOOOOooooUUUUuuuuNnCc'
    )))::VARCHAR;
$$;

COMMENT ON FUNCTION academico_test.fn_menu_codigo_canonico(VARCHAR)
    IS 'Forma canonica de un TMENU.CODIGO: UPPER + TRIM + sin tildes/dieresis/cedilla (translate, porque la extension unaccent no esta instalada). Sirve para comparar codigos de menu sin depender de como quedaron escritos en cada ambiente: en produccion el grupo es GESTION_ACADEMICA y la documentacion original de V396 lo daba por GESTIÓN_ACÁDEMICA. V396.';

-- 0.b CODIGO real (tal como esta en la fila) del menu PADRE del submenu cuyo
--     codigo canonico es p_codigo_hijo. Devuelve NULL si el submenu no existe
--     o no tiene padre => el caller falla cerrado con 42501.
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
