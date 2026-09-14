-- ============================================================================
-- V369 — completa el ciclo de vida real de "Funcionarios" en PIGSE
-- (front_pigse/features/establishment/employees), que hasta ahora estaba
-- copiado de Colombia Evaluadora (rol+jornada+estado por permiso, "Información
-- complementaria") sin que ese modelo exista en pigse.* (ver V257/V360:
-- pigse.TFUNCIONARIO no tiene jornada ni estado por rol, y PIGSE no tiene
-- sedes -- V365).
--
-- Dos huecos reales que este archivo cierra:
--
-- 1. PUT /funcionarios/:ID (uuid 'pigse-funcionarios-actualizar', V258) solo
--    pasaba 4 de los 10 parámetros que `pigse.fn_fun_actualizar` (V257) ya
--    soporta -- segundo_nombre/segundo_apellido/telefono/tipo_documento/
--    cargo/establecimiento viajaban en el body del front y se perdían porque
--    la query registrada nunca los reenviaba a la función SQL. Se actualiza
--    el texto para pasar la firma completa (misma técnica que V360 con
--    'pigse-establecimientos-crear/-actualizar': UPDATE por uuid, no se edita
--    V258 in-place).
--
-- 2. No existe forma de asignar/cambiar el rol de un funcionario YA CREADO:
--    `fn_fun_crear` solo asigna rol en el momento del alta (y solo si ya
--    tiene establecimiento); un funcionario "pendiente" que luego recibe
--    establecimiento vía PUT, o alguien al que se le quiere cambiar el rol,
--    no tenía ningún endpoint para eso. `pigse.fn_fun_asignar_rol` (NUEVA)
--    cierra ese hueco: fija el rol dentro del establecimiento del
--    funcionario -- de ahí "asignar" y no "agregar": desactiva cualquier
--    otro rol que ese usuario tuviera activo en ESE MISMO establecimiento
--    (y limpia public.role_users si no le queda ningún otro vínculo con ese
--    rol en otro establecimiento/ente) antes de activar el nuevo, para que
--    el front pueda modelarlo como un <select> de un solo rol, igual que
--    el resto de esta pantalla.
-- ============================================================================

SET search_path TO pigse, academico_test, public;

-- ---------------------------------------------------------------------------
-- 1. PUT /funcionarios/:ID -- firma completa de fn_fun_actualizar.
-- ---------------------------------------------------------------------------
UPDATE public.query
   SET query = $q$SELECT pigse.fn_fun_actualizar(
              public.fn_get_pigse_usuario_id(CAST(:CONTEXT.USER_ID AS BIGINT)),
              CAST(:PARAM.ID AS BIGINT),
              CAST(:BODY.CORREO_ELECTRONICO AS VARCHAR),
              CAST(:BODY.IDENTIFICACION AS VARCHAR),
              CAST(:BODY.PRIMER_NOMBRE AS VARCHAR),
              CAST(:BODY.SEGUNDO_NOMBRE AS VARCHAR),
              CAST(:BODY.PRIMER_APELLIDO AS VARCHAR),
              CAST(:BODY.SEGUNDO_APELLIDO AS VARCHAR),
              CAST(:BODY.TELEFONO AS VARCHAR),
              CAST(:BODY.FK_TLV_TIPO_DOCUMENTO AS BIGINT),
              CAST(:BODY.FK_TLV_CARGO AS BIGINT),
              CAST(:BODY.FK_ESTABLECIMIENTO AS BIGINT)
          ) AS actualizado$q$,
       param_types = '{"PARAM.ID": "BIGINT!", "BODY.CORREO_ELECTRONICO": "VARCHAR",
         "BODY.IDENTIFICACION": "VARCHAR", "BODY.PRIMER_NOMBRE": "VARCHAR",
         "BODY.SEGUNDO_NOMBRE": "VARCHAR", "BODY.PRIMER_APELLIDO": "VARCHAR",
         "BODY.SEGUNDO_APELLIDO": "VARCHAR", "BODY.TELEFONO": "VARCHAR",
         "BODY.FK_TLV_TIPO_DOCUMENTO": "BIGINT", "BODY.FK_TLV_CARGO": "BIGINT",
         "BODY.FK_ESTABLECIMIENTO": "BIGINT"}'::jsonb
 WHERE uuid = 'pigse-funcionarios-actualizar';

-- ---------------------------------------------------------------------------
-- 2. pigse.fn_fun_asignar_rol (NUEVA): fija el rol de un funcionario dentro
--    de su establecimiento actual.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pigse.fn_fun_asignar_rol(
    p_pk_usuario_solicitante BIGINT,
    p_pk_funcionario         BIGINT,
    p_fk_id_role             BIGINT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pigse, academico_test, public
AS $$
DECLARE
    v_pk_usuario         BIGINT;
    v_fk_establecimiento BIGINT;
    v_active             BOOLEAN;
    v_old_role           BIGINT;
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    IF NOT pigse.fn_usuario_tiene_rol(p_pk_usuario_solicitante,
            ARRAY['PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL']::VARCHAR[]) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    IF p_fk_id_role IS NULL THEN
        RAISE EXCEPTION 'El rol es obligatorio' USING ERRCODE = '23502';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.role r WHERE r.id_role = p_fk_id_role) THEN
        RAISE EXCEPTION 'El rol (%) no existe en public.role', p_fk_id_role USING ERRCODE = '23503';
    END IF;

    SELECT f.FK_TUSUARIO, f.FK_TESTABLECIMIENTO, f.ACTIVE
      INTO v_pk_usuario, v_fk_establecimiento, v_active
      FROM pigse.TFUNCIONARIO f
     WHERE f.PK_TFUNCIONARIO = p_pk_funcionario;

    IF NOT FOUND OR v_active = FALSE THEN
        RAISE EXCEPTION 'No se encontro el funcionario solicitado (%)', p_pk_funcionario
            USING ERRCODE = 'P0002';
    END IF;

    IF v_fk_establecimiento IS NULL THEN
        RAISE EXCEPTION 'El funcionario (%) todavia no tiene establecimiento -- asignalo primero (PUT /funcionarios/%)', p_pk_funcionario, p_pk_funcionario
            USING ERRCODE = '22023';
    END IF;

    -- Desactiva cualquier OTRO rol que ya tuviera en ESTE establecimiento
    -- (un funcionario tiene un solo rol por EE en el front actual) y limpia
    -- public.role_users si ese rol no le queda vigente por ningún otro
    -- establecimiento/ente -- sin esto, quitarle "Rector" en el EE A dejaria
    -- el claim de rol en el JWT aunque ya no aplique en ningun lado.
    FOR v_old_role IN
        SELECT DISTINCT eu.FK_ID_ROLE
          FROM pigse.TESTABLECIMIENTO_USUARIO eu
         WHERE eu.FK_TUSUARIO = v_pk_usuario
           AND eu.FK_TESTABLECIMIENTO = v_fk_establecimiento
           AND eu.ACTIVE = TRUE
           AND eu.FK_ID_ROLE <> p_fk_id_role
    LOOP
        UPDATE pigse.TESTABLECIMIENTO_USUARIO
           SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TUSUARIO = v_pk_usuario
           AND FK_TESTABLECIMIENTO = v_fk_establecimiento
           AND FK_ID_ROLE = v_old_role
           AND ACTIVE = TRUE;

        IF NOT EXISTS (
            SELECT 1 FROM pigse.TESTABLECIMIENTO_USUARIO eu
             WHERE eu.FK_TUSUARIO = v_pk_usuario AND eu.FK_ID_ROLE = v_old_role AND eu.ACTIVE = TRUE
             UNION ALL
            SELECT 1 FROM pigse.TENTE_USUARIO eu
             WHERE eu.FK_TUSUARIO = v_pk_usuario AND eu.FK_ID_ROLE = v_old_role AND eu.ACTIVE = TRUE
        ) THEN
            DELETE FROM public.role_users ru
             WHERE ru.role_id = v_old_role
               AND ru.user_id = (SELECT u.FK_ID_USER FROM pigse.TUSUARIO u WHERE u.PK_TUSUARIO = v_pk_usuario);
        END IF;
    END LOOP;

    PERFORM pigse.fn_est_usuario_crear(
        p_pk_usuario_solicitante, v_pk_usuario, v_fk_establecimiento, p_fk_id_role
    );

    RETURN TRUE;
END;
$$;

COMMENT ON FUNCTION pigse.fn_fun_asignar_rol(BIGINT, BIGINT, BIGINT)
    IS 'V369: fija (reemplaza) el rol de un funcionario dentro de su establecimiento actual -- desactiva cualquier otro rol que tuviera en ese mismo EE (limpiando public.role_users si no le queda vigente en otro EE/ente) y activa el nuevo via fn_est_usuario_crear. Requiere que el funcionario ya tenga establecimiento (no aplica a pendientes).';

INSERT INTO public.query (uuid, query, type, microservice_id, path_template, execution_mode, http_method, param_types)
SELECT 'pigse-funcionarios-asignar-rol',
       $q$SELECT pigse.fn_fun_asignar_rol(
              public.fn_get_pigse_usuario_id(CAST(:CONTEXT.USER_ID AS BIGINT)),
              CAST(:PARAM.ID AS BIGINT),
              CAST(:BODY.FK_ID_ROLE AS BIGINT)
          ) AS asignado$q$,
       'postgres', m.id_microservice, '/funcionarios/:ID/rol', 'SELECT', 'POST',
       '{"PARAM.ID": "BIGINT!", "BODY.FK_ID_ROLE": "BIGINT!"}'::jsonb
  FROM public.microservice m WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = 'pigse-funcionarios-asignar-rol');

INSERT INTO public.role_query (query_id, role_id)
SELECT q.id_query, ro.id_role
  FROM public.query q
 CROSS JOIN public.role ro
 WHERE q.uuid = 'pigse-funcionarios-asignar-rol'
   AND ro.name IN ('PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL')
   AND NOT EXISTS (SELECT 1 FROM public.role_query rq WHERE rq.query_id = q.id_query AND rq.role_id = ro.id_role);

-- ---------------------------------------------------------------------------
-- 3. GET /establecimientos/opciones -- lista liviana (id + nombre) de TODOS
--    los establecimientos activos, sin paginar. El front YA lo llama
--    (`useEstablishmentsOptionsQuery`, pensado para selectores globales como
--    el de esta pantalla) pero nunca existió para 'pigse' -- respondía 400.
-- ---------------------------------------------------------------------------
INSERT INTO public.query (uuid, query, type, microservice_id, path_template, execution_mode, http_method, param_types)
SELECT 'pigse-establecimientos-opciones',
       $q$SELECT PK_ESTABLECIMIENTO AS id, NOMBRE AS name
            FROM pigse.TESTABLECIMIENTO
           WHERE ACTIVE = TRUE
           ORDER BY NOMBRE$q$,
       'postgres', m.id_microservice, '/establecimientos/opciones', 'SELECT', 'GET', '{}'::jsonb
  FROM public.microservice m WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = 'pigse-establecimientos-opciones');

INSERT INTO public.role_query (query_id, role_id)
SELECT q.id_query, ro.id_role
  FROM public.query q
 CROSS JOIN public.role ro
 WHERE q.uuid = 'pigse-establecimientos-opciones'
   AND ro.name IN ('PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL',
                   'PIGSE-DIRECTOR_ENTE_TERRITORIAL', 'PIGSE-JEFE_SISTEMA_ENTE_TERRITORIAL',
                   'PIGSE-JEFE_AREA_PLANEACION', 'PIGSE-JEFE_AREA_COBERTURA', 'PIGSE-JEFE_AREA_CALIDAD',
                   'PIGSE-RECTOR', 'PIGSE-JEFE_SISTEMA_ESTABLECIMIENTO',
                   'PIGSE-AUXILIAR_ADMINISTRATIVO')
   AND NOT EXISTS (SELECT 1 FROM public.role_query rq WHERE rq.query_id = q.id_query AND rq.role_id = ro.id_role);

-- ---------------------------------------------------------------------------
-- Verificacion
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_param_types TEXT;
    v_asignar_rol_binds BIGINT;
    v_opciones_binds BIGINT;
BEGIN
    SELECT param_types::TEXT INTO v_param_types
      FROM public.query WHERE uuid = 'pigse-funcionarios-actualizar';
    IF v_param_types NOT ILIKE '%FK_ESTABLECIMIENTO%' THEN
        RAISE EXCEPTION 'V369 fallo: pigse-funcionarios-actualizar no quedo con FK_ESTABLECIMIENTO en param_types';
    END IF;

    SELECT count(*) INTO v_asignar_rol_binds
      FROM public.role_query rq
      JOIN public.query q ON q.id_query = rq.query_id
     WHERE q.uuid = 'pigse-funcionarios-asignar-rol';
    IF v_asignar_rol_binds != 2 THEN
        RAISE EXCEPTION 'V369 fallo: se esperaban 2 binds para pigse-funcionarios-asignar-rol, se encontraron %', v_asignar_rol_binds;
    END IF;

    SELECT count(*) INTO v_opciones_binds
      FROM public.role_query rq
      JOIN public.query q ON q.id_query = rq.query_id
     WHERE q.uuid = 'pigse-establecimientos-opciones';
    IF v_opciones_binds != 10 THEN
        RAISE EXCEPTION 'V369 fallo: se esperaban 10 binds para pigse-establecimientos-opciones, se encontraron %', v_opciones_binds;
    END IF;

    RAISE NOTICE 'V369 OK: PUT /funcionarios/:ID completo, POST /funcionarios/:ID/rol y GET /establecimientos/opciones registrados.';
END $$;
