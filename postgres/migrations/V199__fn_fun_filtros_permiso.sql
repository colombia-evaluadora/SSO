-- ===========================================================================
-- V199 — filtros que recortan permisos de un funcionario (filas de
-- academico_test.TUSUARIO_ROL_PERMISO): endpoint de escritura
-- (fn_fun_filtros_permiso_actualizar) + endpoint de lectura
-- (fn_fun_filtros_permiso_listar).
--
-- CU-86e2w4xdt — Permisos segun rol.
--
-- QUE HACE
--   1) PUT /api/eval-col/funcionario/:ID/filtros-permiso  (:ID =
--      PK_TFUNCIONARIO, igual que el hermano PUT /funcionario/:ID/permisos
--      que sirve fn_fun_permisos_actualizar de V51). Recibe, por cada rol
--      del funcionario, la lista de menus a recortar con su modo y REEMPLAZA
--      POR COMPLETO el set de filtros activos del funcionario:
--        * los (rol, menu, sede) que llegan en el body -> INSERT o REACTIVATE
--          (patron "buscar-y-decidir", NO ON CONFLICT: el esquema usa indices
--          parciales WHERE active = true — mismo criterio que V123).
--        * las filas TUSUARIO_ROL_PERMISO activas del funcionario que NO
--          estan en el nuevo set -> ACTIVE = FALSE.
--      filtros: [] (o menus: []) => limpia todos los filtros del funcionario.
--      MODIFIED_BY / MODIFIED_AT solo se tocan cuando hubo cambio real.
--
--   2) GET /api/eval-col/funcionario/:ID/filtros-permiso — lee el estado
--      actual: una fila por filtro ACTIVE del funcionario, ya resuelto a
--      (rolId, rolNombre, menuId, menuNombre, fkTsede, sedeNombre, modo).
--      Es el read-back necesario para que el front construya el payload del
--      PUT (que es reemplazo completo). Mismo gate y mismo role_query que el
--      PUT. `modo` se deriva de SOLO_LECTURA con la misma regla que V185:
--      'SI' => 'SOLO_LECTURA', cualquier otro valor => 'BLOQUEO_TOTAL'.
--
-- POR QUE
--   Hoy TUSUARIO_ROL_PERMISO solo se LEE (fn_usuario_permisos_menu de V185);
--   no habia forma de escribirla por API. Este es el lado de escritura.
--
-- RELACION CON V185 / V99 — SEMANTICA DE SOLO_LECTURA
--   V185 (fn_usuario_permisos_menu) interpreta TUSUARIO_ROL_PERMISO.SOLO_LECTURA
--   (VARCHAR(5)) asi, por combinacion (rol, menu):
--     * 'SI'                      -> recorte de SOLO LECTURA: bloquea
--                                    crear/editar/eliminar, deja ver.
--     * cualquier otro valor, NULL incluido (IS DISTINCT FROM 'SI')
--                                -> BLOQUEO TOTAL: los 4 permisos en FALSE.
--   Esta funcion persiste explicitamente:
--     modo SOLO_LECTURA  -> SOLO_LECTURA = 'SI'
--     modo BLOQUEO_TOTAL -> SOLO_LECTURA = 'NO'   (greppable; V185 ya lo
--                           trata como bloqueo total via IS DISTINCT FROM 'SI').
--   `modo` se compara UPPER(TRIM(...)) — case-insensitive y sin espacios.
--
-- ALCANCE (FK_TSEDE) — DERIVADO, NO LO MANDA EL CALLER
--   Para cada rol, el alcance sale del TSEDE_USUARIO ACTIVE del funcionario
--   para ese rol: PREDETERMINADO = 1 si existe, si no el de menor ORDEN.
--   Si el funcionario NO tiene TSEDE_USUARIO activo para ese rol ->
--   status = 'rol_no_asignado' (no se toca nada para ese menu).
--   FK_ENTE se deja SIEMPRE en NULL: el CHECK de la tabla exige exactamente
--   uno de FK_TSEDE / FK_ENTE, y aqui el alcance es siempre por sede. Los
--   roles que se asignan por ente territorial (no por sede) quedan FUERA de
--   este endpoint — por eso la fila role_query de abajo NO incluye los
--   roles de ente territorial. Soportar FK_ENTE seria un follow-up.
--
-- GATE
--   Copiado 1:1 del bloque "0. Gate" de fn_fun_permisos_actualizar (V51,
--   ~linea 1260): super-admin (fn_puede_afectar_establecimiento) O
--   rector/secretaria/jefe de sistema de AL MENOS UN EE donde el funcionario
--   objetivo sea alcanzable, O coordinador de sede (autoridad limitada a
--   roles 9-14). El caller NO elige sede en este endpoint (se deriva), por
--   eso NO se replica la materializacion v_sedes_plenas/v_sedes_coord que el
--   hermano usa para validar cada operacion contra la sede que afecta.
--   El gate fino real vive en esta funcion; role_query va ancho.
--
-- ERRCODES (consistentes con V51 / V113)
--   P0002  funcionario inexistente.
--   22023  funcionario inactivo | p_filtros mal formado | elemento sin
--          rolId o menuId | modo invalido.
--   42501  gate.
--
-- IDEMPOTENCIA
--   CREATE OR REPLACE FUNCTION. El registro public.query usa
--   ON CONFLICT (microservice_id, path_template, http_method) DO NOTHING y
--   role_query ON CONFLICT DO NOTHING. Re-ejecutar el archivo es inofensivo.
--
-- CAVEAT DE RECARGA
--   Fila nueva en public.query => 404 por el gateway hasta reiniciar el
--   contenedor query-service-eval-col.
-- ===========================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_fun_filtros_permiso_actualizar(
    p_pk_usuario_solicitante bigint,
    p_pk_funcionario         bigint,
    p_filtros                jsonb
)
RETURNS TABLE(
    rol_id                  bigint,
    menu_id                 bigint,
    pk_tusuario_rol_permiso bigint,
    status                  character varying
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_usuario     BIGINT;
    v_active_fun     BOOLEAN;
    v_nombre_actual  VARCHAR;
    v_es_super       BOOLEAN;
    v_visible        BOOLEAN;
    v_actor          VARCHAR(120) := 'usuario:' || COALESCE(p_pk_usuario_solicitante::text, 'null');
    v_now            TIMESTAMP := CURRENT_TIMESTAMP;
    v_keep           BIGINT[] := ARRAY[]::BIGINT[];
    v_item           RECORD;
    v_fk_trol_menu   BIGINT;
    v_fk_sede        BIGINT;
    v_sl_val         VARCHAR(5);
    v_existing_pk    BIGINT;
    v_existing_act   BOOLEAN;
    v_existing_sl    VARCHAR(5);
BEGIN
    -- =====================================================================
    -- 1. Existencia y estado del TFUNCIONARIO. Resolver PK_TUSUARIO y un
    --    nombre legible para los mensajes.
    -- =====================================================================
    SELECT f.ACTIVE, f.FK_TUSUARIO,
           TRIM(COALESCE(u.PRIMER_NOMBRE,'') || ' ' || COALESCE(u.PRIMER_APELLIDO,''))
      INTO v_active_fun, v_pk_usuario, v_nombre_actual
      FROM academico_test.TFUNCIONARIO f
      JOIN academico_test.TUSUARIO      u ON u.PK_TUSUARIO = f.FK_TUSUARIO
     WHERE f.PK_TFUNCIONARIO = p_pk_funcionario;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el funcionario solicitado'
            USING ERRCODE = 'P0002';
    END IF;
    IF v_active_fun = FALSE THEN
        RAISE EXCEPTION 'El funcionario "%" esta inactivo; no se puede actualizar', v_nombre_actual
            USING ERRCODE = '22023';
    END IF;

    -- =====================================================================
    -- 0. Gate de autorizacion -- copiado de fn_fun_permisos_actualizar
    --    (V51): "union de EE accesibles" + coordinador de sede.
    -- =====================================================================
    v_es_super := academico_test.fn_puede_afectar_establecimiento(p_pk_usuario_solicitante);

    IF NOT v_es_super THEN
        WITH ee_accesibles AS (
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT DISTINCT s.FK_TESTABLECIMIENTO
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
             WHERE s.ACTIVE = TRUE AND su.ACTIVE = TRUE AND su.FK_TROL = 8 AND su.FK_TUSUARIO = p_pk_usuario_solicitante
        ),
        sedes_coordinador AS (
            SELECT su.FK_TSEDE
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
             WHERE s.ACTIVE = TRUE AND su.ACTIVE = TRUE AND su.FK_TROL = 11 AND su.FK_TUSUARIO = p_pk_usuario_solicitante
        )
        SELECT EXISTS (
            SELECT 1
              FROM academico_test.TESTABLECIMIENTO e
             WHERE e.ACTIVE = TRUE
               AND e.PK_ESTABLECIMIENTO IN (SELECT PK_ESTABLECIMIENTO FROM ee_accesibles)
               AND (e.FK_TFUNCIONARIO_RECTOR = p_pk_funcionario OR e.FK_TFUNCIONARIO_SECRETARIA = p_pk_funcionario)
            UNION ALL
            SELECT 1
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
             WHERE su.FK_TUSUARIO = v_pk_usuario
               AND su.ACTIVE      = TRUE
               AND s.ACTIVE       = TRUE
               AND s.FK_TESTABLECIMIENTO IN (SELECT PK_ESTABLECIMIENTO FROM ee_accesibles)
               AND su.FK_TROL >= 7 AND su.FK_TROL NOT IN (15, 16)
            UNION ALL
            SELECT 1
              FROM academico_test.TSEDE_USUARIO su
             WHERE su.FK_TUSUARIO = v_pk_usuario
               AND su.ACTIVE      = TRUE
               AND su.FK_TSEDE IN (SELECT FK_TSEDE FROM sedes_coordinador)
               AND su.FK_TROL >= 9 AND su.FK_TROL NOT IN (15, 16)
        ) INTO v_visible;

        IF NOT v_visible THEN
            RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
                USING ERRCODE = '42501';
        END IF;
    END IF;

    -- =====================================================================
    -- 2. Validacion estructural de p_filtros.
    -- =====================================================================
    IF p_filtros IS NULL OR jsonb_typeof(p_filtros) <> 'array' THEN
        RAISE EXCEPTION 'p_filtros debe ser un JSON array [{"rolId":..,"menus":[..]}]'
            USING ERRCODE = '22023';
    END IF;

    -- Cada elemento debe traer rolId; si trae "menus", debe ser un array.
    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_filtros) AS e
         WHERE NULLIF(TRIM(e->>'rolId'), '') IS NULL
    ) THEN
        RAISE EXCEPTION 'cada elemento de p_filtros debe traer "rolId"'
            USING ERRCODE = '22023';
    END IF;

    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_filtros) AS e
         WHERE e ? 'menus' AND jsonb_typeof(e->'menus') <> 'array'
    ) THEN
        RAISE EXCEPTION '"menus" debe ser un JSON array en cada elemento de p_filtros'
            USING ERRCODE = '22023';
    END IF;

    -- Cada menu debe traer menuId y un modo valido.
    IF EXISTS (
        SELECT 1
          FROM jsonb_array_elements(p_filtros) AS e
          CROSS JOIN LATERAL jsonb_array_elements(COALESCE(e->'menus', '[]'::jsonb)) AS m
         WHERE NULLIF(TRIM(m->>'menuId'), '') IS NULL
    ) THEN
        RAISE EXCEPTION 'cada menu de p_filtros debe traer "menuId"'
            USING ERRCODE = '22023';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM jsonb_array_elements(p_filtros) AS e
          CROSS JOIN LATERAL jsonb_array_elements(COALESCE(e->'menus', '[]'::jsonb)) AS m
         WHERE UPPER(TRIM(COALESCE(m->>'modo', ''))) NOT IN ('SOLO_LECTURA', 'BLOQUEO_TOTAL')
    ) THEN
        RAISE EXCEPTION 'cada menu de p_filtros debe traer "modo" en {SOLO_LECTURA, BLOQUEO_TOTAL}'
            USING ERRCODE = '22023';
    END IF;

    -- =====================================================================
    -- 3. Procesar el set deseado, fila por fila (buscar-y-decidir).
    --    DISTINCT colapsa duplicados exactos del payload.
    -- =====================================================================
    FOR v_item IN
        SELECT DISTINCT
               (e->>'rolId')::BIGINT                                  AS rol_id,
               (m->>'menuId')::BIGINT                                 AS menu_id,
               UPPER(TRIM(m->>'modo'))                                AS modo
          FROM jsonb_array_elements(p_filtros) AS e
          CROSS JOIN LATERAL jsonb_array_elements(COALESCE(e->'menus', '[]'::jsonb)) AS m
    LOOP
        rol_id                  := v_item.rol_id;
        menu_id                 := v_item.menu_id;
        pk_tusuario_rol_permiso := NULL;

        -- 3.a  Resolver FK_TROL_MENU activo desde (rolId, menuId).
        SELECT rm.PK_TROL_MENU
          INTO v_fk_trol_menu
          FROM academico_test.TROL_MENU rm
         WHERE rm.FK_TROL  = v_item.rol_id
           AND rm.FK_TMENU = v_item.menu_id
           AND rm.ACTIVE   = TRUE
         LIMIT 1;

        IF v_fk_trol_menu IS NULL THEN
            status := 'menu_no_concedido';
            RETURN NEXT;
            CONTINUE;
        END IF;

        -- 3.b  Derivar el alcance (FK_TSEDE) del TSEDE_USUARIO activo del
        --      funcionario para ese rol: PREDETERMINADO=1 si existe, si no
        --      el de menor ORDEN.
        SELECT su.FK_TSEDE
          INTO v_fk_sede
          FROM academico_test.TSEDE_USUARIO su
         WHERE su.FK_TUSUARIO = v_pk_usuario
           AND su.FK_TROL     = v_item.rol_id
           AND su.ACTIVE      = TRUE
         ORDER BY (su.PREDETERMINADO = 1) DESC, su.ORDEN ASC, su.PK_TSEDE_USUARIO ASC
         LIMIT 1;

        IF v_fk_sede IS NULL THEN
            status := 'rol_no_asignado';
            RETURN NEXT;
            CONTINUE;
        END IF;

        v_sl_val := CASE v_item.modo WHEN 'SOLO_LECTURA' THEN 'SI' ELSE 'NO' END;

        -- 3.c  Buscar fila existente (activa o no) para esa combinacion
        --      exacta (usuario, trol_menu, sede).
        SELECT p.PK_TUSUARIO_ROL_PERMISO, p.ACTIVE, p.SOLO_LECTURA
          INTO v_existing_pk, v_existing_act, v_existing_sl
          FROM academico_test.TUSUARIO_ROL_PERMISO p
         WHERE p.FK_TUSUARIO   = v_pk_usuario
           AND p.FK_TROL_MENU  = v_fk_trol_menu
           AND p.FK_TSEDE      = v_fk_sede
         ORDER BY p.ACTIVE DESC, p.PK_TUSUARIO_ROL_PERMISO DESC
         LIMIT 1;

        IF v_existing_pk IS NULL THEN
            INSERT INTO academico_test.TUSUARIO_ROL_PERMISO AS t
                (FK_ENTE, FK_TSEDE, FK_TUSUARIO, FK_TROL_MENU, SOLO_LECTURA, CREATED_BY, ACTIVE)
            VALUES
                (NULL, v_fk_sede, v_pk_usuario, v_fk_trol_menu, v_sl_val, v_actor, TRUE)
            RETURNING t.PK_TUSUARIO_ROL_PERMISO INTO pk_tusuario_rol_permiso;
            status := 'inserted';

        ELSIF v_existing_act = FALSE THEN
            UPDATE academico_test.TUSUARIO_ROL_PERMISO AS t
               SET ACTIVE       = TRUE,
                   SOLO_LECTURA = v_sl_val,
                   MODIFIED_BY  = v_actor,
                   MODIFIED_AT  = v_now
             WHERE t.PK_TUSUARIO_ROL_PERMISO = v_existing_pk;
            pk_tusuario_rol_permiso := v_existing_pk;
            status := 'reactivated';

        ELSIF v_existing_sl IS DISTINCT FROM v_sl_val THEN
            UPDATE academico_test.TUSUARIO_ROL_PERMISO AS t
               SET SOLO_LECTURA = v_sl_val,
                   MODIFIED_BY  = v_actor,
                   MODIFIED_AT  = v_now
             WHERE t.PK_TUSUARIO_ROL_PERMISO = v_existing_pk;
            pk_tusuario_rol_permiso := v_existing_pk;
            status := 'actualizado';

        ELSE
            pk_tusuario_rol_permiso := v_existing_pk;
            status := 'sin_cambio';
        END IF;

        v_keep := v_keep || pk_tusuario_rol_permiso;
        RETURN NEXT;
    END LOOP;

    -- =====================================================================
    -- 4. Reemplazo completo: desactivar las filas activas del funcionario
    --    que NO quedaron en el nuevo set. MODIFIED_* solo en las que
    --    realmente cambian (el WHERE ya garantiza ACTIVE = TRUE).
    -- =====================================================================
    RETURN QUERY
    WITH deact AS (
        UPDATE academico_test.TUSUARIO_ROL_PERMISO p
           SET ACTIVE      = FALSE,
               MODIFIED_BY = v_actor,
               MODIFIED_AT = v_now
         WHERE p.FK_TUSUARIO = v_pk_usuario
           AND p.ACTIVE      = TRUE
           AND NOT (p.PK_TUSUARIO_ROL_PERMISO = ANY (v_keep))
        RETURNING p.PK_TUSUARIO_ROL_PERMISO, p.FK_TROL_MENU
    )
    SELECT rm.FK_TROL, rm.FK_TMENU, d.PK_TUSUARIO_ROL_PERMISO, 'deactivated'::varchar
      FROM deact d
      JOIN academico_test.TROL_MENU rm ON rm.PK_TROL_MENU = d.FK_TROL_MENU;

    RETURN;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_fun_filtros_permiso_actualizar(BIGINT, BIGINT, JSONB)
    IS 'Reemplazo completo por funcionario de los filtros que recortan sus permisos (filas academico_test.TUSUARIO_ROL_PERMISO). p_pk_funcionario = PK_TFUNCIONARIO. p_filtros = [{"rolId":<bigint>,"menus":[{"menuId":<bigint>,"modo":"SOLO_LECTURA"|"BLOQUEO_TOTAL"}]}]. Por cada (rol, menu): resuelve FK_TROL_MENU activo desde (rolId,menuId); deriva FK_TSEDE del TSEDE_USUARIO activo del funcionario para ese rol (PREDETERMINADO=1, si no menor ORDEN), FK_ENTE siempre NULL; persiste SOLO_LECTURA=''SI'' para SOLO_LECTURA y ''NO'' para BLOQUEO_TOTAL (semantica V185: IS DISTINCT FROM ''SI'' = bloqueo total). Patron buscar-y-decidir (sin ON CONFLICT): insert / reactivate / update de modo / sin_cambio. Las filas activas del funcionario que no quedan en el nuevo set pasan a ACTIVE=FALSE. filtros/menus vacios => limpia todo. Devuelve una fila por (rol,menu) procesado: status en {inserted, reactivated, actualizado, sin_cambio, deactivated, menu_no_concedido, rol_no_asignado}. ERRCODES: P0002 funcionario inexistente; 22023 funcionario inactivo / p_filtros mal formado / elemento sin rolId o menuId / modo invalido; 42501 gate (mismo bloque "union de EE accesibles" + coordinador de sede que fn_fun_permisos_actualizar de V51). modo se compara UPPER(TRIM(...)).';


-- ---------------------------------------------------------------------------
-- Registro en public.query (motor SSO / query-service): PUT
-- /funcionario/:ID/filtros-permiso  (serviceid 'eval-col').
--
-- microservice_id se resuelve por serviceid='eval-col' (no id literal —
-- varia por entorno; mismo patron que V185/V198). Si esa fila no existe en
-- el entorno donde corre esta migracion, el INSERT ... SELECT no produce
-- filas (no rompe).
--
-- El gate REAL lo hace la funcion (fn_fun_filtros_permiso_actualizar);
-- role_query aqui va ancho, a los mismos roles que el hermano id_query 113
-- (PUT /funcionario/:ID/permisos) EXCEPTO los de ente territorial — este
-- endpoint deriva el alcance de TSEDE_USUARIO y solo escribe FK_TSEDE.
--
-- Idempotente: ON CONFLICT (microservice_id, path_template, http_method)
-- DO NOTHING.
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_fun_filtros_permiso_actualizar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.FILTROS AS JSONB)
);',
    'postgres', false, false,
    m.id_microservice, '/funcionario/:ID/filtros-permiso', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "BODY.FILTROS": "JSONB"}'::jsonb,
    'V199 -- reemplazo completo por funcionario de los filtros que recortan sus permisos (TUSUARIO_ROL_PERMISO). Body: {"filtros":[{"rolId":N,"menus":[{"menuId":N,"modo":"SOLO_LECTURA"|"BLOQUEO_TOTAL"}]}]}. modo SOLO_LECTURA => TUSUARIO_ROL_PERMISO.SOLO_LECTURA=''SI'' (recorta crear/editar/eliminar, deja ver); BLOQUEO_TOTAL => ''NO'' (los 4 en false, semantica V185). filtros:[] limpia todo. El gate lo hace la funcion.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

-- role_query: mismos roles que el hermano id_query 113 salvo ente territorial.
INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r
    ON r.name IN (
        'CEVAL-SUPER_ADMINISTRADOR',
        'SSO-ADMIN',
        'CEVAL-RECTOR',
        'CEVAL-AUXILIAR_ADMINISTRATIVO',
        'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO'
    )
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/funcionario/:ID/filtros-permiso'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;


-- ===========================================================================
-- fn_fun_filtros_permiso_listar — GET /funcionario/:ID/filtros-permiso.
--   Read-back del estado actual de los filtros de un funcionario, resuelto a
--   nombres, para que el front pueda construir el payload del PUT (reemplazo
--   completo). Una fila por TUSUARIO_ROL_PERMISO ACTIVE del funcionario.
--   `modo` se deriva de SOLO_LECTURA igual que en V185
--   (IS DISTINCT FROM 'SI' => BLOQUEO_TOTAL).
--   Mismo gate que fn_fun_filtros_permiso_actualizar (bloque "0. Gate" de
--   fn_fun_permisos_actualizar de V51). LEFT JOIN a TSEDE para que una fila
--   con alcance por ente (FK_ENTE, sembrada fuera de este endpoint) siga
--   apareciendo con fk_tsede / sede_nombre en NULL en vez de desaparecer.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_fun_filtros_permiso_listar(
    p_pk_usuario_solicitante bigint,
    p_pk_funcionario         bigint
)
RETURNS TABLE(
    rol_id      bigint,
    rol_nombre  character varying,
    menu_id     bigint,
    menu_nombre character varying,
    fk_tsede    bigint,
    sede_nombre character varying,
    modo        character varying
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_pk_usuario    BIGINT;
    v_active_fun    BOOLEAN;
    v_nombre_actual VARCHAR;
    v_es_super      BOOLEAN;
    v_visible       BOOLEAN;
BEGIN
    -- 1. Existencia y estado del TFUNCIONARIO -> PK_TUSUARIO.
    SELECT f.ACTIVE, f.FK_TUSUARIO,
           TRIM(COALESCE(u.PRIMER_NOMBRE,'') || ' ' || COALESCE(u.PRIMER_APELLIDO,''))
      INTO v_active_fun, v_pk_usuario, v_nombre_actual
      FROM academico_test.TFUNCIONARIO f
      JOIN academico_test.TUSUARIO      u ON u.PK_TUSUARIO = f.FK_TUSUARIO
     WHERE f.PK_TFUNCIONARIO = p_pk_funcionario;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el funcionario solicitado'
            USING ERRCODE = 'P0002';
    END IF;

    -- 0. Gate -- copiado de fn_fun_permisos_actualizar (V51).
    v_es_super := academico_test.fn_puede_afectar_establecimiento(p_pk_usuario_solicitante);

    IF NOT v_es_super THEN
        WITH ee_accesibles AS (
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT DISTINCT s.FK_TESTABLECIMIENTO
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
             WHERE s.ACTIVE = TRUE AND su.ACTIVE = TRUE AND su.FK_TROL = 8 AND su.FK_TUSUARIO = p_pk_usuario_solicitante
        ),
        sedes_coordinador AS (
            SELECT su.FK_TSEDE
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
             WHERE s.ACTIVE = TRUE AND su.ACTIVE = TRUE AND su.FK_TROL = 11 AND su.FK_TUSUARIO = p_pk_usuario_solicitante
        )
        SELECT EXISTS (
            SELECT 1
              FROM academico_test.TESTABLECIMIENTO e
             WHERE e.ACTIVE = TRUE
               AND e.PK_ESTABLECIMIENTO IN (SELECT PK_ESTABLECIMIENTO FROM ee_accesibles)
               AND (e.FK_TFUNCIONARIO_RECTOR = p_pk_funcionario OR e.FK_TFUNCIONARIO_SECRETARIA = p_pk_funcionario)
            UNION ALL
            SELECT 1
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
             WHERE su.FK_TUSUARIO = v_pk_usuario
               AND su.ACTIVE      = TRUE
               AND s.ACTIVE       = TRUE
               AND s.FK_TESTABLECIMIENTO IN (SELECT PK_ESTABLECIMIENTO FROM ee_accesibles)
               AND su.FK_TROL >= 7 AND su.FK_TROL NOT IN (15, 16)
            UNION ALL
            SELECT 1
              FROM academico_test.TSEDE_USUARIO su
             WHERE su.FK_TUSUARIO = v_pk_usuario
               AND su.ACTIVE      = TRUE
               -- alias explicito: la funcion tiene un OUT param fk_tsede que
               -- haria ambiguo un `SELECT FK_TSEDE` a secas.
               AND su.FK_TSEDE IN (SELECT sc.FK_TSEDE FROM sedes_coordinador sc)
               AND su.FK_TROL >= 9 AND su.FK_TROL NOT IN (15, 16)
        ) INTO v_visible;

        IF NOT v_visible THEN
            RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
                USING ERRCODE = '42501';
        END IF;
    END IF;

    -- 2. Filas activas, resueltas a nombres.
    RETURN QUERY
    SELECT rm.FK_TROL                                        AS rol_id,
           tr.NOMBRE                                         AS rol_nombre,
           rm.FK_TMENU                                       AS menu_id,
           tm.NOMBRE                                         AS menu_nombre,
           p.FK_TSEDE                                        AS fk_tsede,
           ts.NOMBRE                                         AS sede_nombre,
           CASE WHEN p.SOLO_LECTURA IS DISTINCT FROM 'SI'
                THEN 'BLOQUEO_TOTAL' ELSE 'SOLO_LECTURA' END::varchar AS modo
      FROM academico_test.TUSUARIO_ROL_PERMISO p
      JOIN academico_test.TROL_MENU rm ON rm.PK_TROL_MENU = p.FK_TROL_MENU
      JOIN academico_test.TROL      tr ON tr.PK_TROL      = rm.FK_TROL
      JOIN academico_test.TMENU     tm ON tm.PK_TMENU     = rm.FK_TMENU
      LEFT JOIN academico_test.TSEDE ts ON ts.PK_TSEDE    = p.FK_TSEDE
     WHERE p.FK_TUSUARIO = v_pk_usuario
       AND p.ACTIVE      = TRUE
     ORDER BY tr.NOMBRE, tm.NOMBRE, p.FK_TSEDE;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_fun_filtros_permiso_listar(BIGINT, BIGINT)
    IS 'Read-back de los filtros que recortan permisos de un funcionario (filas academico_test.TUSUARIO_ROL_PERMISO ACTIVE). p_pk_funcionario = PK_TFUNCIONARIO. Una fila por filtro, resuelta a (rol_id, rol_nombre, menu_id, menu_nombre, fk_tsede, sede_nombre, modo). modo se deriva de SOLO_LECTURA con la regla de V185: ''SI'' => ''SOLO_LECTURA''; cualquier otro valor (NULL incluido) => ''BLOQUEO_TOTAL''. LEFT JOIN a TSEDE: una fila con alcance por ente (FK_ENTE, no la escribe este endpoint) aparece con fk_tsede/sede_nombre en NULL. Mismo gate que fn_fun_filtros_permiso_actualizar. ERRCODES: P0002 funcionario inexistente; 42501 gate. Sirve para que el front arme el payload del PUT (reemplazo completo).';

-- Registro en public.query: GET /funcionario/:ID/filtros-permiso (eval-col).
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_fun_filtros_permiso_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice, '/funcionario/:ID/filtros-permiso', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    'V199 -- lee los filtros activos que recortan los permisos de un funcionario (TUSUARIO_ROL_PERMISO), resueltos a nombres: (rolId, rolNombre, menuId, menuNombre, fkTsede, sedeNombre, modo). Read-back para construir el payload del PUT /funcionario/:ID/filtros-permiso.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

-- role_query: mismos roles que el PUT.
INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r
    ON r.name IN (
        'CEVAL-SUPER_ADMINISTRADOR',
        'SSO-ADMIN',
        'CEVAL-RECTOR',
        'CEVAL-AUXILIAR_ADMINISTRATIVO',
        'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO'
    )
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/funcionario/:ID/filtros-permiso'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;
