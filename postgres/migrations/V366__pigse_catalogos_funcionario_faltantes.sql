-- ============================================================================
-- V366 — catálogos y endpoints de funcionario que front_pigse necesita y
-- nunca existieron para 'pigse' (llamaba a `/eval-col/...` de CEVAL --
-- hardcodeado, mismo patrón que el bug de registro de funcionario/escudo
-- ya corregido esta sesión). Mirror del set real de 'eval-col' (V58/V119),
-- adaptado a las tablas propias de pigse (V256/V257).
--
-- FUERA DE ALCANCE (deliberado): `PUT /funcionario/:id/permisos`
-- (fn_fun_permisos_actualizar en CEVAL) trabaja sobre el concepto
-- rol+jornada POR SEDE -- PIGSE no tiene sedes (ver V365) ni jornadas por
-- sede, así que ese endpoint no tiene un equivalente directo. Queda
-- pendiente de una decisión de producto, igual que "Sedes".
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. GET /select  (categorias existentes de pigse.tlista_valor)
-- ---------------------------------------------------------------------------
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT gen_random_uuid()::text,
       'SELECT DISTINCT categoria FROM pigse.tlista_valor',
       'postgres', false, false, m.id_microservice, '/select', 'SELECT', 'GET', '{}'::jsonb,
       'Catalogo generico PIGSE: categorias existentes en tlista_valor.'
  FROM public.microservice m
 WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE microservice_id = m.id_microservice AND path_template = '/select' AND http_method = 'GET');

-- ---------------------------------------------------------------------------
-- 2. GET /select/:CATEGORIA
-- ---------------------------------------------------------------------------
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT gen_random_uuid()::text,
       $q$select pk_lista_valor, nombre, valor, accion
           from pigse.tlista_valor
          where pigse.tlista_valor.categoria = UPPER(CAST(:PARAM.CATEGORIA AS VARCHAR))
            and active = true
          order by valor asc$q$,
       'postgres', false, false, m.id_microservice, '/select/:CATEGORIA', 'SELECT', 'GET',
       '{"PARAM.CATEGORIA":"VARCHAR"}'::jsonb,
       'Catalogo generico PIGSE: filas de una categoria de tlista_valor.'
  FROM public.microservice m
 WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE microservice_id = m.id_microservice AND path_template = '/select/:CATEGORIA' AND http_method = 'GET');

-- ---------------------------------------------------------------------------
-- 3. GET /catalogos/discapacidades -- pigse no tiene TDISCAPACIDAD propia
--    (a diferencia de CEVAL): se modela como categoria TIPO_DISCAPACIDAD
--    de tlista_valor, aliaseada a la forma que espera el front
--    (pk_discapacidad/codigo/nombre).
-- ---------------------------------------------------------------------------
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT gen_random_uuid()::text,
       $q$SELECT pk_lista_valor AS pk_discapacidad, valor AS codigo, nombre
           FROM pigse.tlista_valor
          WHERE categoria = 'TIPO_DISCAPACIDAD' AND active = true
          ORDER BY nombre$q$,
       'postgres', false, false, m.id_microservice, '/catalogos/discapacidades', 'SELECT', 'GET', '{}'::jsonb,
       'Catalogo de tipos de discapacidad activos (tlista_valor.TIPO_DISCAPACIDAD), para el select del formulario de funcionario/establecimiento PIGSE.'
  FROM public.microservice m
 WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE microservice_id = m.id_microservice AND path_template = '/catalogos/discapacidades' AND http_method = 'GET');

-- ---------------------------------------------------------------------------
-- 4. GET /catalogos/municipios -- pigse.tmunicipio + tdepartamento propios.
-- ---------------------------------------------------------------------------
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT gen_random_uuid()::text,
       $q$SELECT m2.pk_tmunicipio AS pk_municipio, m2.nombre,
               d.pk_departamento, d.nombre AS departamento_nombre
          FROM pigse.tmunicipio m2
          JOIN pigse.tdepartamento d ON d.pk_departamento = m2.pk_tdepartamento
         WHERE m2.active = true
         ORDER BY d.nombre, m2.nombre$q$,
       'postgres', false, false, m.id_microservice, '/catalogos/municipios', 'SELECT', 'GET', '{}'::jsonb,
       'Catalogo de municipios activos con su departamento resuelto (pigse.tmunicipio/tdepartamento), para el select de municipio de PIGSE.'
  FROM public.microservice m
 WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE microservice_id = m.id_microservice AND path_template = '/catalogos/municipios' AND http_method = 'GET');

-- ---------------------------------------------------------------------------
-- 5. GET /catalogos/propiedad-juridica -- pigse.tpropiedad_juridica propia.
-- ---------------------------------------------------------------------------
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT gen_random_uuid()::text,
       $q$SELECT pk_propiedad_juridica, codigo, nombre
           FROM pigse.tpropiedad_juridica
          WHERE active = true
          ORDER BY nombre$q$,
       'postgres', false, false, m.id_microservice, '/catalogos/propiedad-juridica', 'SELECT', 'GET', '{}'::jsonb,
       'Catalogo de tipos de propiedad juridica activos (pigse.tpropiedad_juridica), para el select del formulario de establecimiento PIGSE.'
  FROM public.microservice m
 WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE microservice_id = m.id_microservice AND path_template = '/catalogos/propiedad-juridica' AND http_method = 'GET');

-- ---------------------------------------------------------------------------
-- 6. GET /catalogos/roles -- roles asignables a un funcionario de PIGSE.
--    PIGSE no tiene TROL propia (a diferencia de CEVAL): los roles viven
--    en public.role, ligados a la app via role_app. Se excluyen los roles
--    de fiscalizacion/administracion (PIGSE-ADMINISTRADOR,
--    PIGSE-SECRETARIA_TERRITORIAL) -- mismo criterio que CEVAL excluye sus
--    roles de sistema (PK_TROL < 9): esos no se asignan desde el alta de
--    un funcionario normal.
-- ---------------------------------------------------------------------------
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT gen_random_uuid()::text,
       $q$SELECT r.id_role AS pk_rol, r.name AS codigo, COALESCE(r.description, r.name) AS nombre
           FROM public.role r
           JOIN public.role_app ra ON ra.id_role = r.id_role
           JOIN public.app a ON a.id_app = ra.id_app
          WHERE a.name = 'PIGSE'
            AND r.name NOT IN ('PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL')
          ORDER BY COALESCE(r.description, r.name)$q$,
       'postgres', false, false, m.id_microservice, '/catalogos/roles', 'SELECT', 'GET', '{}'::jsonb,
       'Catalogo de roles asignables a un funcionario de PIGSE (public.role via role_app), excluyendo los roles de fiscalizacion/administracion.'
  FROM public.microservice m
 WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE microservice_id = m.id_microservice AND path_template = '/catalogos/roles' AND http_method = 'GET');

-- ---------------------------------------------------------------------------
-- 7. GET /usuarios/autocompletar-por-documento -- busca un pigse.tusuario
--    existente por (tipo de documento, identificacion) para precargar el
--    formulario de alta de funcionario/rector-secretaria.
-- ---------------------------------------------------------------------------
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT gen_random_uuid()::text,
       $q$SELECT u.pk_tusuario, u.identificacion, u.primer_nombre, u.segundo_nombre,
               u.primer_apellido, u.segundo_apellido, u.fecha_nacimiento,
               u.fk_tlv_genero, lv.nombre AS genero_nombre, u.telefono,
               u.correo_electronico, u.fk_tarchivo AS fk_tarchivo_foto,
               (SELECT f.pk_tfuncionario FROM pigse.tfuncionario f
                 WHERE f.fk_tusuario = u.pk_tusuario AND f.active = true
                 LIMIT 1) AS pk_tfuncionario_activo
          FROM pigse.tusuario u
          LEFT JOIN pigse.tlista_valor lv ON lv.pk_lista_valor = u.fk_tlv_genero
         WHERE u.active = true
           AND u.fk_tlv_tipo_documento = CAST(:QUERY.FKTLVTIPODOCUMENTO AS BIGINT)
           AND u.identificacion = CAST(:QUERY.IDENTIFICACION AS VARCHAR)
         LIMIT 1$q$,
       'postgres', false, false, m.id_microservice, '/usuarios/autocompletar-por-documento', 'SELECT', 'GET',
       '{"QUERY.IDENTIFICACION":"VARCHAR","QUERY.FKTLVTIPODOCUMENTO":"BIGINT"}'::jsonb,
       'Autocompletado del form de persona (rector/secretaria/funcionario PIGSE): busca un pigse.tusuario existente por documento.'
  FROM public.microservice m
 WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE microservice_id = m.id_microservice AND path_template = '/usuarios/autocompletar-por-documento' AND http_method = 'GET');

-- ---------------------------------------------------------------------------
-- 8. Baja en bloque de establecimientos y funcionarios (soft-delete).
-- ---------------------------------------------------------------------------
-- Forma de fila SIN envelope -- {pk_establecimiento, status} por cada id,
-- "eliminado" en exito o "error:<razon>" en fallo -- mismo contrato ya
-- confirmado contra el backend real para funcionarios (ver
-- BulkDeleteEstablishmentRow/BulkDeleteEmployeeRow en front_pigse).
CREATE OR REPLACE FUNCTION pigse.fn_est_soft_delete_bulk(
    p_pk_usuario_solicitante BIGINT,
    p_pks BIGINT[]
)
RETURNS TABLE (pk_establecimiento VARCHAR, status VARCHAR)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pigse, academico_test, public
AS $$
DECLARE
    v_pk BIGINT;
BEGIN
    IF NOT pigse.fn_usuario_tiene_rol(p_pk_usuario_solicitante,
            ARRAY['PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL']::VARCHAR[]) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    FOREACH v_pk IN ARRAY COALESCE(p_pks, ARRAY[]::BIGINT[])
    LOOP
        IF NOT EXISTS (SELECT 1 FROM pigse.TESTABLECIMIENTO e WHERE e.PK_ESTABLECIMIENTO = v_pk AND e.ACTIVE = TRUE) THEN
            RETURN QUERY SELECT v_pk::VARCHAR, 'error:no_encontrado'::VARCHAR;
            CONTINUE;
        END IF;

        UPDATE pigse.TESTABLECIMIENTO
           SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_ESTABLECIMIENTO = v_pk;

        RETURN QUERY SELECT v_pk::VARCHAR, 'eliminado'::VARCHAR;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION pigse.fn_fun_baja_bulk(
    p_pk_usuario_solicitante BIGINT,
    p_pks BIGINT[]
)
RETURNS TABLE (pk_funcionario VARCHAR, status VARCHAR)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pigse, academico_test, public
AS $$
DECLARE
    v_pk BIGINT;
BEGIN
    IF NOT pigse.fn_usuario_tiene_rol(p_pk_usuario_solicitante,
            ARRAY['PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL']::VARCHAR[]) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    FOREACH v_pk IN ARRAY COALESCE(p_pks, ARRAY[]::BIGINT[])
    LOOP
        IF NOT EXISTS (SELECT 1 FROM pigse.TFUNCIONARIO f WHERE f.PK_TFUNCIONARIO = v_pk AND f.ACTIVE = TRUE) THEN
            RETURN QUERY SELECT v_pk::VARCHAR, 'error:no_encontrado'::VARCHAR;
            CONTINUE;
        END IF;

        -- Un funcionario que sea rector/secretaria vigente de un EE no se
        -- puede dar de baja por este camino -- mismo principio que
        -- fn_fun_cancelar_pendiente (V360): primero hay que reasignar el EE.
        IF EXISTS (
            SELECT 1 FROM pigse.TESTABLECIMIENTO e
             WHERE e.FK_TFUNCIONARIO_RECTOR = v_pk OR e.FK_TFUNCIONARIO_SECRETARIA = v_pk
        ) THEN
            RETURN QUERY SELECT v_pk::VARCHAR, 'error:es_rector_o_secretaria'::VARCHAR;
            CONTINUE;
        END IF;

        UPDATE pigse.TFUNCIONARIO
           SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TFUNCIONARIO = v_pk;

        RETURN QUERY SELECT v_pk::VARCHAR, 'eliminado'::VARCHAR;
    END LOOP;
END;
$$;

INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT gen_random_uuid()::text,
       $q$SELECT * FROM pigse.fn_est_soft_delete_bulk(
           public.fn_get_pigse_usuario_id(:CONTEXT.USER_ID::BIGINT),
           CAST(:BODY.PKS AS BIGINT[])
       )$q$,
       'postgres', false, false, m.id_microservice, '/establecimientos/bulk-delete', 'SELECT', 'POST',
       '{"BODY.PKS":"BIGINT[]"}'::jsonb,
       'Baja en bloque de establecimientos PIGSE (soft-delete).'
  FROM public.microservice m
 WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE microservice_id = m.id_microservice AND path_template = '/establecimientos/bulk-delete' AND http_method = 'POST');

INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT gen_random_uuid()::text,
       $q$SELECT * FROM pigse.fn_fun_baja_bulk(
           public.fn_get_pigse_usuario_id(:CONTEXT.USER_ID::BIGINT),
           CAST(:BODY.PKS AS BIGINT[])
       )$q$,
       'postgres', false, false, m.id_microservice, '/establecimientos/funcionarios/eliminar-multiple', 'SELECT', 'PUT',
       '{"BODY.PKS":"BIGINT[]"}'::jsonb,
       'Baja en bloque de funcionarios PIGSE (soft-delete).'
  FROM public.microservice m
 WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE microservice_id = m.id_microservice AND path_template = '/establecimientos/funcionarios/eliminar-multiple' AND http_method = 'PUT');

-- ---------------------------------------------------------------------------
-- 9. role_query: mismos roles que ya tienen acceso al resto del modulo de
--    funcionarios/establecimientos PIGSE (V258/V360).
-- ---------------------------------------------------------------------------
INSERT INTO public.role_query (role_id, query_id)
SELECT ro.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  CROSS JOIN public.role ro
 WHERE m.serviceid = 'pigse'
   AND ro.name IN ('PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL')
   AND (q.path_template, q.http_method) IN (
       ('/select', 'GET'), ('/select/:CATEGORIA', 'GET'),
       ('/catalogos/discapacidades', 'GET'), ('/catalogos/municipios', 'GET'),
       ('/catalogos/propiedad-juridica', 'GET'), ('/catalogos/roles', 'GET'),
       ('/usuarios/autocompletar-por-documento', 'GET'),
       ('/establecimientos/bulk-delete', 'POST'),
       ('/establecimientos/funcionarios/eliminar-multiple', 'PUT')
   )
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- Verificación
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_queries BIGINT;
    v_binds   BIGINT;
BEGIN
    SELECT count(*) INTO v_queries
      FROM public.query q
      JOIN public.microservice m ON m.id_microservice = q.microservice_id
     WHERE m.serviceid = 'pigse'
       AND (q.path_template, q.http_method) IN (
           ('/select', 'GET'), ('/select/:CATEGORIA', 'GET'),
           ('/catalogos/discapacidades', 'GET'), ('/catalogos/municipios', 'GET'),
           ('/catalogos/propiedad-juridica', 'GET'), ('/catalogos/roles', 'GET'),
           ('/usuarios/autocompletar-por-documento', 'GET'),
           ('/establecimientos/bulk-delete', 'POST'),
           ('/establecimientos/funcionarios/eliminar-multiple', 'PUT')
       );

    SELECT count(DISTINCT (q.path_template, q.http_method)) INTO v_binds
      FROM public.role_query rq
      JOIN public.role ro ON ro.id_role = rq.role_id
      JOIN public.query q ON q.id_query = rq.query_id
      JOIN public.microservice m ON m.id_microservice = q.microservice_id
     WHERE m.serviceid = 'pigse'
       AND ro.name = 'PIGSE-ADMINISTRADOR'
       AND (q.path_template, q.http_method) IN (
           ('/select', 'GET'), ('/select/:CATEGORIA', 'GET'),
           ('/catalogos/discapacidades', 'GET'), ('/catalogos/municipios', 'GET'),
           ('/catalogos/propiedad-juridica', 'GET'), ('/catalogos/roles', 'GET'),
           ('/usuarios/autocompletar-por-documento', 'GET'),
           ('/establecimientos/bulk-delete', 'POST'),
           ('/establecimientos/funcionarios/eliminar-multiple', 'PUT')
       );

    RAISE NOTICE 'V366: % queries nuevas, % binds a PIGSE-ADMINISTRADOR (esperado 9/9)', v_queries, v_binds;

    IF v_queries != 9 THEN
        RAISE EXCEPTION 'V366 fallo: se esperaban 9 queries nuevas, se encontraron %', v_queries;
    END IF;
    IF v_binds != 9 THEN
        RAISE WARNING 'V366: PIGSE-ADMINISTRADOR quedo con % de 9 binds', v_binds;
    END IF;
END $$;
