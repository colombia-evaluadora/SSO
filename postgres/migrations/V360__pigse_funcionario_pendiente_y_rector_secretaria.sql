-- ===========================================================================
-- V360 - PIGSE: funcionario pendiente (FK_TESTABLECIMIENTO nullable) y rector/
-- secretaria en TESTABLECIMIENTO, con sus endpoints. fn_fun_crear y fn_est_*
-- de 14 parametros viven hoy en V362 y V370.
-- ===========================================================================


SET search_path TO pigse, academico_test, public;

ALTER TABLE pigse.tfuncionario ALTER COLUMN FK_TESTABLECIMIENTO DROP NOT NULL;

ALTER TABLE pigse.testablecimiento
  ADD COLUMN IF NOT EXISTS FK_TFUNCIONARIO_RECTOR BIGINT,
  ADD COLUMN IF NOT EXISTS FK_TFUNCIONARIO_SECRETARIA BIGINT;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'fk_pigse_testablecimiento_rector'
    ) THEN
        ALTER TABLE pigse.testablecimiento
            ADD CONSTRAINT FK_PIGSE_TESTABLECIMIENTO_RECTOR
            FOREIGN KEY (FK_TFUNCIONARIO_RECTOR) REFERENCES pigse.tfuncionario (PK_TFUNCIONARIO);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'fk_pigse_testablecimiento_secretaria'
    ) THEN
        ALTER TABLE pigse.testablecimiento
            ADD CONSTRAINT FK_PIGSE_TESTABLECIMIENTO_SECRETARIA
            FOREIGN KEY (FK_TFUNCIONARIO_SECRETARIA) REFERENCES pigse.tfuncionario (PK_TFUNCIONARIO);
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS IDX_PIGSE_TESTABLECIMIENTO_RECTOR ON pigse.testablecimiento (FK_TFUNCIONARIO_RECTOR);

CREATE INDEX IF NOT EXISTS IDX_PIGSE_TESTABLECIMIENTO_SECRETARIA ON pigse.testablecimiento (FK_TFUNCIONARIO_SECRETARIA);

COMMENT ON COLUMN pigse.testablecimiento.FK_TFUNCIONARIO_RECTOR
    IS 'V360: rector del establecimiento. Se asigna con el PK del TFUNCIONARIO ya registrado (posiblemente pendiente, sin EE todavia) al crear/actualizar el establecimiento -- espejo de academico_test.testablecimiento (V22).';

COMMENT ON COLUMN pigse.testablecimiento.FK_TFUNCIONARIO_SECRETARIA
    IS 'V360: secretaria del establecimiento. Mismo criterio que FK_TFUNCIONARIO_RECTOR.';

CREATE OR REPLACE FUNCTION pigse.fn_fun_cancelar_pendiente(
    p_pk_usuario_solicitante BIGINT,
    p_pk_funcionario         BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pigse, academico_test, public
AS $$
DECLARE
    v_fk_usuario BIGINT;
    v_active     BOOLEAN;
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;
    IF p_pk_funcionario IS NULL OR p_pk_funcionario <= 0 THEN
        RAISE EXCEPTION 'p_pk_funcionario es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    SELECT FK_TUSUARIO, ACTIVE
      INTO v_fk_usuario, v_active
      FROM pigse.TFUNCIONARIO
     WHERE PK_TFUNCIONARIO = p_pk_funcionario;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el funcionario solicitado'
            USING ERRCODE = 'P0002';
    END IF;

    IF v_active = FALSE THEN
        RETURN p_pk_funcionario;
    END IF;

    IF EXISTS (
        SELECT 1
          FROM pigse.TESTABLECIMIENTO e
         WHERE e.ACTIVE = TRUE
           AND p_pk_funcionario IN (e.FK_TFUNCIONARIO_RECTOR, e.FK_TFUNCIONARIO_SECRETARIA)
    ) THEN
        RAISE EXCEPTION 'Este funcionario ya esta asignado como rector/secretaria de un establecimiento -- no es un pendiente cancelable'
            USING ERRCODE = '22023',
                  HINT    = 'Un funcionario ya asignado se reemplaza reasignando el rol del EE, o se da de baja con pigse.fn_fun_soft_delete';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM pigse.TESTABLECIMIENTO_USUARIO tu
         WHERE tu.FK_TUSUARIO = v_fk_usuario
           AND tu.ACTIVE      = TRUE
    ) THEN
        RAISE EXCEPTION 'Este funcionario ya tiene permisos asignados -- no es un pendiente cancelable'
            USING ERRCODE = '22023',
                  HINT    = 'Usa pigse.fn_fun_soft_delete para dar de baja a un funcionario real';
    END IF;

    -- Gate: dueno del pendiente (auto-servicio, rollback del propio submit
    -- fallido) siempre pasa; cualquier otro solicitante necesita el nivel
    -- de permisos que ya exige el resto de este modulo. Igual que en
    -- academico_test: no hay scope/rango que comparar -- un pendiente
    -- cancelable acaba de validarse arriba como sin EE ni permisos activos.
    IF v_fk_usuario IS DISTINCT FROM p_pk_usuario_solicitante THEN
        IF NOT pigse.fn_usuario_tiene_rol(p_pk_usuario_solicitante,
                ARRAY['PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL']::VARCHAR[]) THEN
            RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
                USING ERRCODE = '42501';
        END IF;
    END IF;

    UPDATE pigse.TFUNCIONARIO
       SET ACTIVE      = FALSE,
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TFUNCIONARIO = p_pk_funcionario;

    RAISE NOTICE 'pigse.TFUNCIONARIO % pendiente cancelado por usuario %', p_pk_funcionario, p_pk_usuario_solicitante;

    RETURN p_pk_funcionario;
END;
$$;

COMMENT ON FUNCTION pigse.fn_fun_cancelar_pendiente(BIGINT, BIGINT)
    IS 'V360: cancela (soft delete) un pigse.TFUNCIONARIO que todavia no se uso en ningun lado -- ni es rector/secretaria de un establecimiento activo (TESTABLECIMIENTO.FK_TFUNCIONARIO_RECTOR/SECRETARIA), ni tiene ningun TESTABLECIMIENTO_USUARIO activo. Mismo contrato que academico_test.fn_fun_cancelar_pendiente (V51 REV5): rechaza con 22023 si ya esta en uso, idempotente si ya estaba inactivo, auto-servicio para el dueno del pendiente o gate de nivel de permisos para cualquier otro.';

UPDATE public.query
   SET query = $q$SELECT pigse.fn_est_crear(
              public.fn_get_pigse_usuario_id(CAST(:CONTEXT.USER_ID AS BIGINT)),
              CAST(:BODY.FK_ENTE AS BIGINT),
              CAST(:BODY.NOMBRE AS VARCHAR),
              CAST(:BODY.NIT AS VARCHAR),
              CAST(:BODY.FK_TMUNICIPIO AS BIGINT),
              CAST(:BODY.CODIGO AS VARCHAR),
              NULL, NULL, NULL, NULL, NULL, NULL,
              CAST(:BODY.PRINCIPAL AS BIGINT),
              CAST(:BODY.SECRETARY AS BIGINT)
          ) AS pk_establecimiento$q$,
       param_types = '{"BODY.FK_ENTE": "BIGINT!", "BODY.NOMBRE": "VARCHAR!", "BODY.NIT": "VARCHAR!",
         "BODY.FK_TMUNICIPIO": "BIGINT!", "BODY.CODIGO": "VARCHAR!",
         "BODY.PRINCIPAL": "BIGINT", "BODY.SECRETARY": "BIGINT"}'::jsonb
 WHERE uuid = 'pigse-establecimientos-crear';

UPDATE public.query
   SET query = $q$SELECT pigse.fn_est_actualizar(
              public.fn_get_pigse_usuario_id(CAST(:CONTEXT.USER_ID AS BIGINT)),
              CAST(:PARAM.ID AS BIGINT),
              CAST(:BODY.NOMBRE AS VARCHAR),
              CAST(:BODY.NIT AS VARCHAR),
              CAST(:BODY.CODIGO AS VARCHAR),
              CAST(:BODY.FK_TMUNICIPIO AS BIGINT),
              NULL, NULL, NULL, NULL, NULL, NULL,
              CAST(:BODY.PRINCIPAL AS BIGINT),
              CAST(:BODY.SECRETARY AS BIGINT)
          ) AS actualizado$q$,
       param_types = '{"PARAM.ID": "BIGINT!", "BODY.NOMBRE": "VARCHAR", "BODY.NIT": "VARCHAR",
         "BODY.FK_TMUNICIPIO": "BIGINT", "BODY.CODIGO": "VARCHAR",
         "BODY.PRINCIPAL": "BIGINT", "BODY.SECRETARY": "BIGINT"}'::jsonb
 WHERE uuid = 'pigse-establecimientos-actualizar';

INSERT INTO public.endpoint (method, path, description, numberparams)
VALUES ('POST', '/register/pigse/funcionario', 'Registrar funcionario PIGSE', 0)
ON CONFLICT (path, method, description) DO NOTHING;

INSERT INTO public.role_endpoint (endpoint_id, role_id)
SELECT e.id_endpoint, r.id_role
  FROM public.endpoint e, public.role r
 WHERE (e.method, e.path) = ('POST', '/register/pigse/funcionario')
   AND r.name IN ('SSO-ADMIN', 'ADMIN', 'PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL')
ON CONFLICT DO NOTHING;

INSERT INTO public.endpoint_microservice (endpoint_id, microservice_id)
SELECT e.id_endpoint, m.id_microservice
  FROM public.endpoint e
  JOIN public.microservice m ON m.serviceid = 'auth-center'
 WHERE (e.method, e.path) = ('POST', '/register/pigse/funcionario')
   AND NOT EXISTS (
       SELECT 1 FROM public.endpoint_microservice em
        WHERE em.endpoint_id = e.id_endpoint AND em.microservice_id = m.id_microservice
   );

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-pigse360-cnclpnd1',
    'SELECT pigse.fn_fun_cancelar_pendiente(
    public.fn_get_pigse_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.PKFUNCIONARIO AS BIGINT)
) AS pk_funcionario_cancelado;',
    'postgres', false, false,
    m.id_microservice,
    '/funcionario/cancelar-pendiente', 'SELECT', 'POST',
    '{"BODY.PKFUNCIONARIO": "BIGINT"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL
  FROM public.microservice m
 WHERE m.serviceid = 'pigse'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL', 'SSO-ADMIN')
 WHERE m.serviceid     = 'pigse'
   AND q.path_template = '/funcionario/cancelar-pendiente'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'pigse' AND table_name = 'tfuncionario'
           AND column_name = 'fk_testablecimiento' AND is_nullable = 'NO'
    ) THEN
        RAISE EXCEPTION 'V360 fallo: pigse.tfuncionario.fk_testablecimiento sigue NOT NULL';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'pigse' AND table_name = 'testablecimiento'
           AND column_name IN ('fk_tfuncionario_rector', 'fk_tfuncionario_secretaria')
        HAVING COUNT(*) = 2
    ) THEN
        RAISE EXCEPTION 'V360 fallo: faltan columnas rector/secretaria en pigse.testablecimiento';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.query q
          JOIN public.microservice m ON m.id_microservice = q.microservice_id
         WHERE m.serviceid = 'pigse'
           AND q.path_template = '/funcionario/cancelar-pendiente'
           AND q.http_method = 'POST'
    ) THEN
        RAISE EXCEPTION 'V360 fallo: no quedo registrado POST /funcionario/cancelar-pendiente bajo el microservicio pigse';
    END IF;

    RAISE NOTICE 'V360 OK: pigse.tfuncionario admite pendientes, testablecimiento tiene rector/secretaria, fn_fun_cancelar_pendiente, el puente de usuario y el endpoint del microservicio pigse existen.';
END $$;
